---
title: Breakups and Reconciliations,  Solving N+1 Across Database Boundaries
date: 2025-12-12T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["python", "Django", "Optimization"]
categories: ["programming"]
---

In a single database setup, when we need that a Django Database object
references another tables, to diminish the amount of atomic searches (N+1) we
would use `prefetch_related()` in case of ManyToMany relationships and
`select_related()` in OneToOne or ManyToOne relationships. But what happens
when your data lives in two different databases?

Imagine you're building a monitoring system. Your time-series events live in a
specialized database optimized for write-heavy workloads (think TimescaleDB,
InfluxDB, or even a separate PostgreSQL instance). Meanwhile, your reference
data—users, devices, locations—lives in your primary application database, and
you need to display those events with human-readable context.

For example, you have two databases:

**Database A (Time-Series DB)**: Stores order events
```python
# Using Database A (router sends this to timeseries DB)
class OrderEvent(models.Model):
    timestamp = models.DateTimeField(primary_key=True)
    customer_id = models.IntegerField()  # Just an ID, not a foreign key!
    event_type = models.CharField(max_length=50)
    amount = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        db_table = 'order_events'
        managed = False
```

**Database B (Application DB)**: Stores customer details
```python
# Using Database B (your default database)
class Customer(models.Model):
    name = models.CharField(max_length=200)
    email = models.EmailField()
    tier = models.CharField(max_length=20)
```

Now you need to build an API that shows recent order events with customer names.

So you accept that you need to do the lookup in application code. Here's the
straightforward approach:

```python
class OrderEventSerializer(serializers.ModelSerializer):
    customer_name = serializers.SerializerMethodField()
    customer_tier = serializers.SerializerMethodField()

    class Meta:
        model = OrderEvent
        fields = ['timestamp', 'customer_id', 'customer_name',
                  'customer_tier', 'event_type', 'amount']

    def get_customer_name(self, obj):
        try:
            customer = Customer.objects.using('app_db').get(id=obj.customer_id)
            return customer.name
        except Customer.DoesNotExist:
            return 'Unknown Customer'

    def get_customer_tier(self, obj):
        try:
            customer = Customer.objects.using('app_db').get(id=obj.customer_id)
            return customer.tier
        except Customer.DoesNotExist:
            return None
```

This works, but look at what happens when you serialize 100 order events:

```python
# In your viewset
queryset = OrderEvent.objects.using('timeseries_db').all()[:100]
serializer = OrderEventSerializer(queryset, many=True)
data = serializer.data
```

**Query count**:
- 1 query to fetch 100 events from Database A
- 200 queries to Database B (2 per event: one for name, one for tier)
- **Total: 201 queries**

This is the cross-database N+1 problem, and it's worse than the traditional
version:

- **Different connection pools**: Each query hits a different database
connection

- **Network latency**: Potentially different servers, different network paths

- **No foreign keys**: The database can't enforce referential integrity

- **No ORM magic**: `select_related()` and `prefetch_related()` only work within
a single database

**Django's ORM query optimization tools assume a single database**. When you
break that assumption, you're on your own. Let's fix this.

The information required to construct the serialized data is in the
**Serializer Context**, and we can change that method to add the information
needed for the fields that are from the other database. We can override
`get_serializer_context()` in Your Viewset like this:

```python
class OrderEventViewSet(ReadOnlyModelViewSet):
    queryset = OrderEvent.objects.using('timeseries_db').all()
    serializer_class = OrderEventSerializer

    def get_serializer_context(self):
        """
        Pre-fetch all customer data and pass it via context.
        This prevents N+1 queries to the application database.
        """
        context = super().get_serializer_context()

        # Single query to Database B - fetch all customers we might need
        customers = Customer.objects.using('app_db').all()

        # Build a lookup dictionary: customer_id -> customer data
        customer_context = {
            customer.id: {
                'name': customer.name,
                'email': customer.email,
                'tier': customer.tier,
            }
            for customer in customers
        }

        context['customer_context'] = customer_context
        return context
```

Then we can use the added Context in Your Serializer

```python
class OrderEventSerializer(serializers.ModelSerializer):
    customer_name = serializers.SerializerMethodField()
    customer_tier = serializers.SerializerMethodField()

    class Meta:
        model = OrderEvent
        fields = ['timestamp', 'customer_id', 'customer_name',
                  'customer_tier', 'event_type', 'amount']

    def get_customer_name(self, obj):
        customer_context = self.context.get('customer_context', {})
        customer_data = customer_context.get(obj.customer_id)
        return customer_data['name'] if customer_data else 'Unknown Customer'

    def get_customer_tier(self, obj):
        customer_context = self.context.get('customer_context', {})
        customer_data = customer_context.get(obj.customer_id)
        return customer_data['tier'] if customer_data else None
```

This would result in a query simplification as follows

**Query count**:
- 1 query to fetch 100 events from Database A
- 1 query to fetch all customers from Database B
- **Total: 2 queries**

**Performance improvement**: From 201 queries to 2 queries. That's a **99%
reduction**.

The lookup is now O(1) dictionary access instead of O(n) database queries. Each
serialization touches the view context instead of hitting the database.

When implementing this pattern, you need to make several design choices:

* **Context key structure**, the simplest approach is using the foreign key value
  directly, but sometimes you need composite keys. Choose a key structure that
  matches how your events reference the data.

  ```python
  customer_context = {customer.id: customer_data for customer in customers}
  ```
* **Pre-filtering the reference data**, don't store everything if you don't need to

  ```python
  # Bad: Cache ALL customers (could be millions)
  customers = Customer.objects.using('app_db').all()

  # Better: Cache only active customers
  customers = Customer.objects.using('app_db').filter(is_active=True)

  # Even better: Cache only customers in the current events
  event_customer_ids = queryset.values_list('customer_id', flat=True).distinct()
  customers = Customer.objects.using('app_db').filter(id__in=event_customer_ids)
  ```
* **What data to add to the context**, some may say that memory is cheap, but is
  better to be explicit about what is needed, and update the serializer if new
  fields are needed.

  ```python
  customer_context = {
      customer.id: {
          'name': customer.name,
          'tier': customer.tier,
      }
      for customer in customers
  }
  ```
* **Graceful degradation**, because we cannot enforce data matching in different
  databases, always handle missing keys, don't let a missing reference break your
  entire response.

  ```python
  def get_customer_name(self, obj):
      customer_context = self.context.get('customer_context', {})
      customer_data = customer_context.get(obj.customer_id)

      if customer_data:
          return customer_data['name']

      # Graceful fallback
      return f'Unknown Customer (ID: {obj.customer_id})'
  ```
* You can add a Cache Layer if needed. To add information to the context, we
  could also use redis cache or any other solution to store that extra
  information needed for the responses. This solution is extremely useful and
  allows us to implement it in any way that is needed.

  Even though you're trading freshness for performance, choose based on:
  - How often reference data changes (users rarely, prices frequently)
  - How stale you can tolerate (5 minutes? 1 hour?)
  - Request volume (100 req/sec makes caching compelling)

  ```python
  def get_serializer_context(self):
      context = super().get_serializer_context()

      customer_cache = cache.get('customer_cache_v1')
      if not customer_cache:
          customers = Customer.objects.using('app_db').all()
          customer_cache = {c.id: {...} for c in customers}
          cache.set('customer_cache_v1', customer_cache, timeout=300)

      context['customer_context'] = customer_cache
      return context
  ```
## Nothing is Free

Let's examine the trade-offs carefully.

**Memory vs. Network I/O**

**The Trade**: You're loading all reference data into memory for each request.

**When it works**:
- Reference dataset is small (hundreds to low thousands of records)
- Records are lightweight (few fields, no large text/binary data)
- Request frequency is high (many requests per second)

**When it breaks**:
- 100,000+ customers → Gigabytes of memory per request
- Large fields (e.g., full customer profiles with images)
- Low request frequency (memory waste for infrequent requests)

**Rule of thumb**: If your reference data in JSON form is < 10MB, you're
probably fine. Beyond that, consider alternatives.

**Complexity vs. Explicitness**

**The Trade**: This pattern adds cognitive load. Future developers need to understand:
1. Where the context is being built (`get_serializer_context`)
2. How it's used in serializers
3. What happens when data is missing

**Mitigation strategies**:

**Document heavily**:
```python
def get_serializer_context(self):
    """
    PERFORMANCE OPTIMIZATION: Pre-fetch customer data.

    This prevents N+1 queries when serializing order events.
    Each event references a customer_id that lives in a separate database.

    The customer_cache maps customer_id -> customer data dict.
    See OrderEventSerializer.get_customer_name() for usage.
    """
```

**Name things clearly**:
```python
context['customer_context'] = ...
```

**Fail loudly in development**:
```python
def get_customer_name(self, obj):
    cache = self.context.get('customer_cache')

    if cache is None and settings.DEBUG:
        raise ValueError(
            "customer_cache not found in context. "
            "Did you override get_serializer_context()?"
        )

    # ... continue with lookup
```

**Pagination Accuracy**

If you filter data at the application layer, pagination counts might be wrong:

```python
def list(self, request, *args, **kwargs):
    response = super().list(request, *args, **kwargs)

    # Post-serialization filtering
    if isinstance(response.data, list):
        response.data = [
            event for event in response.data
            if event.get('customer_name') != 'Unknown Customer'
        ]

    # Count is now wrong! It counted before filtering.
    return response
```

This might be acceptable for your use case, or you might need to handle it:

```python
# Option 1: Filter in queryset (before serialization)
# Only possible if you can express the filter in SQL

# Option 2: Custom pagination that accounts for filtering
# Complex, usually not worth it

# Option 3: Accept the inaccuracy
# Often the pragmatic choice if filtered items are rare
```

## When to Use This Pattern

If you're dealing with cross-database queries that need to be solved at the
application level and facing N+1 problems, this pattern is your solution. The
main constraint: your reference data needs to fit in memory (< 10MB is a good
rule of thumb).

**Other solutions worth considering**: **Denormalization** - Copy the customer data directly into the events table.
Fastest option, but requires keeping data in sync and accepting some staleness.

**Materialized Views**: Use PostgreSQL foreign data wrappers to create a view
that joins across databases. Requires DBA access and periodic refreshes.

**GraphQL + DataLoader**: If you're already using GraphQL, DataLoader handles
batching automatically.

**Separate API calls from the Frontend**: fetches events and customers
separately, joins client-side.

## Living in the Unknown

Django provides `get_serializer_context()` as an extension point. It's
documented, it's designed for passing data to serializers, and using it for
caching or extending the information needed for the serializer is exactly
what it's meant for. This isn't fighting the framework—it's using it as
intended. Frameworks give you tools, not rules.

Performance isn't optional. Users notice when your app is slow. Infrastructure
costs scale with inefficiency. A 99% reduction in queries isn't premature
optimization—it's fundamental engineering.

Keep the problem in mind, document your code, and measure your improvements.

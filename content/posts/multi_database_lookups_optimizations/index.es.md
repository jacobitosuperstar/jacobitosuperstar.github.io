---
title: Rupturas y reconciliaciones, resolviendo N+1 a través de límites de bases de datos
date: 2025-12-12T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["python", "Django", "Optimización"]
categories: ["programación"]
---

En una configuración de base de datos única, cuando necesitamos que un objeto de
base de datos Django haga referencia a otras tablas, para disminuir la cantidad
de búsquedas atómicas (N+1) usaríamos `prefetch_related()` en caso de
relaciones ManyToMany y `select_related()` en relaciones OneToOne o ManyToOne.
Pero, ¿qué pasa cuando tus datos viven en dos bases de datos diferentes?

Imagina que estás construyendo un sistema de monitoreo. Tus eventos de series
temporales viven en una base de datos especializada optimizada para cargas de
trabajo con muchas escrituras (piensa en TimescaleDB, InfluxDB, o incluso una
instancia separada de PostgreSQL). Mientras tanto, tus datos de
referencia—usuarios, dispositivos, ubicaciones—viven en tu base de datos de
aplicación principal, y necesitas mostrar esos eventos con contexto legible
para humanos.

Por ejemplo, tienes dos bases de datos:

**Base de datos A (Time-Series DB)**: Almacena eventos de pedidos
```python
# Usando Base de datos A (el router envía esto a timeseries DB)
class OrderEvent(models.Model):
    timestamp = models.DateTimeField(primary_key=True)
    customer_id = models.IntegerField()  # Solo un ID, no una clave foránea!
    event_type = models.CharField(max_length=50)
    amount = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        db_table = 'order_events'
        managed = False
```

**Base de datos B (Application DB)**: Almacena detalles de clientes
```python
# Usando Base de datos B (tu base de datos por defecto)
class Customer(models.Model):
    name = models.CharField(max_length=200)
    email = models.EmailField()
    tier = models.CharField(max_length=20)
```

Ahora necesitas construir una API que muestre eventos recientes de pedidos con
nombres de clientes.

## El enfoque ingenuo

Así que aceptas que necesitas hacer la búsqueda en el código de aplicación.
Aquí está el enfoque directo:

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

Esto funciona, pero mira lo que sucede cuando serializas 100 eventos de
pedidos:

```python
# En tu viewset
queryset = OrderEvent.objects.using('timeseries_db').all()[:100]
serializer = OrderEventSerializer(queryset, many=True)
data = serializer.data
```

**Conteo de consultas**:
- 1 consulta para obtener 100 eventos de la Base de datos A
- 200 consultas a la Base de datos B (2 por evento: una para nombre, una para tier)
- **Total: 201 consultas**

Este es el problema N+1 entre bases de datos, y es peor que la versión
tradicional:

- **Diferentes pools de conexión**: Cada consulta golpea una conexión de base
de datos diferente

- **Latencia de red**: Potencialmente diferentes servidores, diferentes rutas
de red

- **Sin claves foráneas**: La base de datos no puede hacer cumplir la
integridad referencial

- **Sin magia del ORM**: `select_related()` y `prefetch_related()` solo
funcionan dentro de una sola base de datos

**Las herramientas de optimización de consultas del ORM de Django asumen una
sola base de datos**. Cuando rompes esa suposición, estás por tu cuenta.
Arreglemos esto.

## Expandiendo el contexto del serializador

La información requerida para construir los datos serializados está en el
**Contexto del Serializador**, y podemos cambiar ese método para agregar la
información necesaria para los campos que son de la otra base de datos.

### Paso 1: Sobrescribir `get_serializer_context()` en tu Viewset

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

        # Una sola consulta a la Base de datos B - obtener todos los clientes que podríamos necesitar
        customers = Customer.objects.using('app_db').all()

        # Construir un diccionario de búsqueda: customer_id -> datos del cliente
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

### Paso 2: Usar el contexto agregado en tu Serializador

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

### El resultado

**Conteo de consultas**:
- 1 consulta para obtener 100 eventos de la Base de datos A
- 1 consulta para obtener todos los clientes de la Base de datos B
- **Total: 2 consultas**

**Mejora de rendimiento**: De 201 consultas a 2 consultas. Eso es una
**reducción del 99%**.

La búsqueda ahora es acceso de diccionario O(1) en lugar de consultas de base
de datos O(n). Cada serialización toca el contexto de la vista en lugar de
golpear la base de datos.

## Decisiones de diseño clave

Al implementar este patrón, necesitas tomar varias decisiones de diseño:

### 1. Estructura de clave del contexto

El enfoque más simple es usar el valor de la clave foránea directamente:

```python
customer_context = {customer.id: customer_data for customer in customers}
```

Pero a veces necesitas claves compuestas. Elige una estructura de clave que
coincida con cómo tus eventos hacen referencia a los datos.

### 2. Pre-filtrado de los datos de referencia

No almacenes todo si no lo necesitas:

```python
# Malo: Cache TODOS los clientes (podrían ser millones)
customers = Customer.objects.using('app_db').all()

# Mejor: Cache solo clientes activos
customers = Customer.objects.using('app_db').filter(is_active=True)

# Aún mejor: Cache solo clientes en los eventos actuales
event_customer_ids = queryset.values_list('customer_id', flat=True).distinct()
customers = Customer.objects.using('app_db').filter(id__in=event_customer_ids)
```

### 3. Qué datos agregar al contexto

**Agregar solo campos necesarios**
```python
customer_context = {
    customer.id: {
        'name': customer.name,
        'tier': customer.tier,
    }
    for customer in customers
}
```

Algunos pueden decir que la memoria es barata, pero es mejor ser explícito
sobre lo que se necesita, y actualizar el serializador si se necesitan nuevos
campos.

### 4. Degradación elegante

Siempre maneja claves faltantes:

```python
def get_customer_name(self, obj):
    customer_context = self.context.get('customer_context', {})
    customer_data = customer_context.get(obj.customer_id)

    if customer_data:
        return customer_data['name']

    # Fallback elegante
    return f'Unknown Customer (ID: {obj.customer_id})'
```

No dejes que una referencia faltante rompa toda tu respuesta de API.

### 5. Agregar una capa de caché si es necesario

Para agregar información al contexto, también podríamos usar caché de redis o
cualquier otra solución para almacenar esa información extra necesaria para las
respuestas. Esta solución es extremadamente útil y nos permite implementarla de
cualquier manera que sea necesaria.

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

Ahora estás intercambiando frescura por rendimiento. Elige basándote en:
- Qué tan a menudo cambian los datos de referencia (usuarios raramente, precios frecuentemente)
- Qué tan obsoleto puedes tolerar (¿5 minutos? ¿1 hora?)
- Volumen de solicitudes (100 req/seg hace que el caché sea atractivo)

## Nada es gratis

Examinemos los compromisos cuidadosamente.

### Memoria vs. I/O de red

**El intercambio**: Estás cargando todos los datos de referencia en memoria
para cada solicitud.

**Cuándo funciona**:
- El conjunto de datos de referencia es pequeño (cientos a miles bajos de registros)
- Los registros son ligeros (pocos campos, sin datos grandes de texto/binarios)
- La frecuencia de solicitudes es alta (muchas solicitudes por segundo)

**Cuándo se rompe**:
- 100,000+ clientes → Gigabytes de memoria por solicitud
- Campos grandes (ej., perfiles completos de clientes con imágenes)
- Baja frecuencia de solicitudes (desperdicio de memoria para solicitudes poco frecuentes)

**Regla general**: Si tus datos de referencia en forma JSON son < 10MB,
probablemente estés bien. Más allá de eso, considera alternativas.

### Complejidad vs. Explicitud

**El intercambio**: Este patrón agrega carga cognitiva. Los desarrolladores
futuros necesitan entender:
1. Dónde se está construyendo el contexto (`get_serializer_context`)
2. Cómo se usa en los serializadores
3. Qué pasa cuando faltan datos

**Estrategias de mitigación**:

**Documenta profusamente**:
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

**Nombra las cosas claramente**:
```python
context['customer_context'] = ...
```

**Falla ruidosamente en desarrollo**:
```python
def get_customer_name(self, obj):
    cache = self.context.get('customer_cache')

    if cache is None and settings.DEBUG:
        raise ValueError(
            "customer_cache not found in context. "
            "Did you override get_serializer_context()?"
        )

    # ... continuar con la búsqueda
```

### Precisión de paginación

Si filtras datos en la capa de aplicación, los conteos de paginación podrían
estar incorrectos:

```python
def list(self, request, *args, **kwargs):
    response = super().list(request, *args, **kwargs)

    # Filtrado post-serialización
    if isinstance(response.data, list):
        response.data = [
            event for event in response.data
            if event.get('customer_name') != 'Unknown Customer'
        ]

    # ¡El conteo ahora está mal! Contó antes del filtrado.
    return response
```

Esto podría ser aceptable para tu caso de uso, o podrías necesitar manejarlo:

```python
# Opción 1: Filtrar en queryset (antes de la serialización)
# Solo posible si puedes expresar el filtro en SQL

# Opción 2: Paginación personalizada que tiene en cuenta el filtrado
# Complejo, usualmente no vale la pena

# Opción 3: Aceptar la inexactitud
# A menudo la elección pragmática si los elementos filtrados son raros
```

## Cuándo usar este patrón

Si estás lidiando con consultas entre bases de datos que necesitan resolverse a
nivel de aplicación y enfrentas problemas N+1, este patrón es tu solución. La
restricción principal: tus datos de referencia necesitan caber en memoria (<
10MB es una buena regla general).

## Otras soluciones dignas de mención

**Desnormalización**: Copia los datos del cliente directamente en la tabla de
eventos. La opción más rápida, pero requiere mantener los datos sincronizados y
aceptar cierta obsolescencia.

**Vistas materializadas**: Usa foreign data wrappers de PostgreSQL para crear
una vista que une a través de bases de datos. Requiere acceso DBA y
actualizaciones periódicas.

**GraphQL + DataLoader**: Si ya estás usando GraphQL, DataLoader maneja el
procesamiento por lotes automáticamente.

**Llamadas API separadas desde el Frontend**: obtiene eventos y clientes por
separado, une del lado del cliente.

## Viviendo en lo desconocido

Django proporciona `get_serializer_context()` como un punto de extensión. Está
documentado, está diseñado para pasar datos a serializadores, y usarlo para
almacenamiento en caché o extender la información necesaria para el serializador
es exactamente para lo que está destinado. Esto no es luchar contra el
framework—es usarlo como se pretende. Los frameworks te dan herramientas, no
reglas.

El rendimiento no es opcional. Los usuarios notan cuando tu aplicación es
lenta. Los costos de infraestructura escalan con la ineficiencia. Una
reducción del 99% en consultas no es optimización prematura—es ingeniería
fundamental.

Mantén el problema en mente, documenta tu código y mide tus mejoras.

---
title: The only useful Nepo babies, Django class-based views
date: 2025-03-05T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["python", "Django"]
categories: ["programming"]
---

While I am not a big fan of the use of OOP in all programming problems and
paradigms, there are places where I can see their usefulness. One of those
places is when creating a simple REST API application. I have known about
Django class-based views from a long time, but the thing is, I have always seen
them as an after though, because they never are what I want them to be, and
before you think about Djando Rest-Framework, I want to tell you that it
doesn't solve either some of the issues that you would normally encounter, like
query optimizations. This guide is intended for people who want to avoid
infinite dependencies and enjoy designing their own solutions, tailored to
their needs.

As part of my Django project structure I like to have a base application called
`base` where I will put much of my custom packages that will be used through
the project.

```log
    base
    ├── __init__.py
    ├── admin.py
    ├── apps.py
    ├── generic_views.py
    ├── http_status_codes.py
    ├── logger.py
    ├── middleware.py
    ├── migrations
    │   └── __init__.py
    ├── mixins.py
    ├── models.py
    ├── response.py
    ├── tests.py
    ├── urls.py
    ├── utils.py
    └── views.py
```

Within the scope of this article I will only talk about `mixins.py` and
`generic_views.py` where I put some of the base code that will compose my
generic views structure.

In case you don't know what mixins are, they are a way to add functionality to
a class by using multiple inheritance. I personally like to create a BaseMixin
that will contain all the base functionality that I think that almost all of my
custom views will use. For example:

```Python
class BaseMixin:
    """Base class that will contain all the common methods that my custom views
    may or may not need.

    Parameters:
        model: type[BaseModel]
            Normally a BaseModel is created that will have all the common
            fields that are shared between all the Models of the app. Like
            creation_time, update_time, is_deleted (for soft delete) and things
            like that.
        form: type[Form]
            Validation form that our view may use to validate the data for
            update, creation or filtering.
        prefetch_fields: List[str]
            All the fields that can be used in the `prefetch_related()`
            functionality.
        select_fields: List[str]
            All the fields that can be used in the `select_related()`
            functionality.
        serializer_depth: int
            There can be nested objects within the queries that need to be
            serialized. This value ensures that we serialize to the desired
            depth and we don't go deeper than needed.
    """
    model: type[BaseModel]
    form: Union[type[Form], None] = None
    prefetch_fields: List[Optional[str]] = []
    select_fields: List[Optional[str]] = []
    serializer_depth: int = 0

    def serialize(self):
        """This is where I would serialize the Model objects to dicts.
        """
        ...

    def validate_form(self):
        """Validate the forms needed for creation, update or filtering of Model
        objects.
        """
        ...

    def all(self):
        """Returns all of the results of a Model object.
        """
        ...

    def filter_query(self):
        """Returns all the results of a Model object after a filter is applied.
        """
        ...

    def get_query(self):
        """Returns singular Model object.
        """
        ...

    def create_object(self):
        """Creates a Model object.
        """
        ...

    def update_object(self):
        """Updates a Model object.
        """
        ...

    def delete_object(self):
        """Deletes a Model object.
        """
        ...
```

Going back to the usefulness of a class-based view, the main idea of using them
is that instead of conditional branches within your general function view given
the HTTP request method, you could just have the required response with
different class instance methods, giving you the opportunity of using something
like this:

```Python
from django.views import View

class GenericView(View):
    def get(self):
        ...
    def post(self):
        ...
    def put(self):
        ...
    def path(self):
        ...
    def delete(self):
        ...
```

Where if an http method is not defined within the view class that we are using,
we would return a HTTP `405` code as a response. In the documentation there is
a more detailed explanation of how a class based view work [look here][1], but
the main idea is that when the url resolver sends the request, an instance of
the class-based view is created and the request is dispatched to the matching
HTTP method function if it exists.

The `View` class from which we are inheriting that functionality, doesn't have
any http methods defined, only the dispatcher that routes the request to them.
Because of this, when we create our own class-based view, we need to define all
the http method that it will accept, otherwise we will only receive `405`
responses.

Knowing all of this, the way on which you create your custom base view, is
through multiple inheritance, between the `BaseMixin` and the `View` class,
where we will define the http method that our view will receive and the
processing needed to send back a response.

Personally I like to create singular class-based views with singular HTTP
methods. That way we simplify view composition and prevent HTTP method
conflicts during multiple inheritance.

As an example, we will create two generic views that each will handle something
different. Taking into account good API practices, normally within the root of
a route, we would do normally two things, a GET method to receive all of the
instances of the objects that belong to that route and a POST method to create a
new entry to the database.

```Python
class BaseListView(BaseMixin, View):
    def get(self, request: HttpRequest, *args, **kwargs) -> JsonResponse:
        """Base List Get View.
        Returns the total amount of objects given the GET request.
        """
        try:
            query_set = self.all()
            data = {
                    self.model._meta.verbose_name_plural: self.serialize(query_set),
            }
            return JsonResponse(data, status=status.ok)
        except Exception as e:
            error_data = {
                "response": _("Internal server error.")
            }
            base_logger.critical(e)
            return JsonResponse(error_data, status=status.internal_server_error)

class BaseCreateView(BaseMixin, View):
    def post(self, request: HttpRequest, *args, **kwargs):
        """Base Post View.
        Creates a db object given the form data in the POST request.
        """
        try:
            form_data = self.validate_form(request=request)
            created_object = self.create_object(data=form_data)
            msg = {
                self.model._meta.verbose_name: self.serialize(created_object),
            }
            return JsonResponse(msg, status=status.created)
        except NotImplementedError as e:
            error_data = e.args[0]
            return JsonResponse(error_data, status=status.internal_server_error)
        except ValidationError as e:
            error_data = e.args[0]
            return JsonResponse(error_data, status=status.bad_request)
        except Exception as e:
            error_data = {
                "response": _("Internal server error.")
            }
            base_logger.critical(e)
            return JsonResponse(error_data, status=status.internal_server_error)
```

*__note__: remember that the `_meta` attribute allows us to access the things
that we defined within the `class Meta` of the model, like `db_table`,
`verbose_name`, `verbose_name_plural` and all the others that you may find
useful. In this case I use those attributes to create a consistent naming
scheme within the JSONResponse.*

And finally, when we are defining our API views, we can use again the powers of
composition and inheritance to add all the functionality that we want from
them, like this:

```Python
class ClientView(
    BaseCreateView,
    BaseListView,
):
    model: type[Client] = Client
    form: type[ClientCreationForm] = ClientCreationForm
    serializer_depth = 0
```

With this, we have a resulting view, that accepts the HTTP methods that we
need, that behaves like we need, and in case we need to change the behaviour
within a HTTP method, we can just re-write or over-write, or create it, like
this:

```Python
class ClientView(
    # BaseCreateView,
    BaseListView,
):
    allowed_roles = [
        RoleChoices.MANAGEMENT,
        RoleChoices.ACCOUNTING,
    ]
    model: type[Client] = Client
    form: type[ClientCreationForm] = ClientCreationForm
    serializer_depth = 0

    def post(self, request: HttpRequest, *args, **kwargs):
        """Custom POST method that only this view needs.
        """
        ...
```

Hopefully this article was useful, and helps you understand how to create the
tools that you may need for your custom necessities.

[1]: https://docs.djangoproject.com/en/dev/topics/class-based-views/intro/

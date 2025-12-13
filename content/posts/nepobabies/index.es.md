---
title: Los únicos Nepo babies útiles, vistas basadas en clases de Django
date: 2025-03-05T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["python", "Django"]
categories: ["programación"]
---

Aunque no soy un gran fanático del uso de POO en todos los problemas y
paradigmas de programación, hay lugares donde puedo ver su utilidad. Uno de
esos lugares es cuando se crea una aplicación de API REST simple. He conocido
las vistas basadas en clases de Django desde hace mucho tiempo, pero la cosa
es que siempre las he visto como una idea tardía, porque nunca son lo que
quiero que sean, y antes de que pienses en Django Rest-Framework, quiero
decirte que tampoco resuelve algunos de los problemas que normalmente
encontrarías, como las optimizaciones de consultas. Esta guía está pensada para
personas que quieren evitar las dependencias infinitas y disfrutan diseñando
soluciones propias, adaptadas a sus necesidades.

Como parte de mi estructura de proyecto Django, me gusta tener una aplicación
base llamada `base` donde pondré muchos de mis paquetes personalizados que se
usarán en todo el proyecto.

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
    │   └── __init__.py
    ├── mixins.py
    ├── models.py
    ├── response.py
    ├── tests.py
    ├── urls.py
    ├── utils.py
    └── views.py
```

Dentro del alcance de este artículo solo hablaré sobre `mixins.py` y
`generic_views.py` donde pongo parte del código base que compondrá mi
estructura de vistas genéricas.

En caso de que no sepas qué son los mixins, son una forma de agregar
funcionalidad a una clase utilizando herencia múltiple. Personalmente me gusta
crear un BaseMixin que contendrá toda la funcionalidad base que creo que casi
todas mis vistas personalizadas usarán. Por ejemplo:

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

Volviendo a la utilidad de una vista basada en clases, la idea principal de
usarlas es que en lugar de ramas condicionales dentro de tu vista de función
general dado el método de solicitud HTTP, podrías simplemente tener la
respuesta requerida con diferentes métodos de instancia de clase, dándote la
oportunidad de usar algo como esto:

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

Donde si un método http no está definido dentro de la clase de vista que
estamos usando, devolveríamos un código HTTP `405` como respuesta. En la
documentación hay una explicación más detallada de cómo funciona una vista
basada en clases [mira aquí][1], pero la idea principal es que cuando el
resolvedor de URL envía la solicitud, se crea una instancia de la vista basada
en clases y la solicitud se despacha a la función del método HTTP
correspondiente si existe.

La clase `View` de la que estamos heredando esa funcionalidad, no tiene ningún
método http definido, solo el despachador que enruta la solicitud a ellos.
Debido a esto, cuando creamos nuestra propia vista basada en clases, necesitamos
definir todos los métodos http que aceptará, de lo contrario solo recibiremos
respuestas `405`.

Sabiendo todo esto, la forma en que creas tu vista base personalizada es a
través de herencia múltiple, entre el `BaseMixin` y la clase `View`, donde
definiremos el método http que nuestra vista recibirá y el procesamiento
necesario para enviar una respuesta.

Personalmente me gusta crear vistas basadas en clases singulares con métodos
HTTP singulares. De esa manera simplificamos la composición de vistas y
prevenimos conflictos de métodos HTTP durante la herencia múltiple.

Como ejemplo, crearemos dos vistas genéricas que cada una manejará algo
diferente. Teniendo en cuenta las buenas prácticas de API, normalmente dentro
de la raíz de una ruta, haríamos normalmente dos cosas, un método GET para
recibir todas las instancias de los objetos que pertenecen a esa ruta y un
método POST para crear una nueva entrada en la base de datos.

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

*__nota__: recuerda que el atributo `_meta` nos permite acceder a las cosas que
definimos dentro del `class Meta` del modelo, como `db_table`, `verbose_name`,
`verbose_name_plural` y todos los demás que puedas encontrar útiles. En este
caso uso esos atributos para crear un esquema de nomenclatura consistente
dentro de la JSONResponse.*

Y finalmente, cuando estamos definiendo nuestras vistas de API, podemos usar
nuevamente los poderes de composición y herencia para agregar toda la
funcionalidad que queramos de ellas, así:

```Python
class ClientView(
    BaseCreateView,
    BaseListView,
):
    model: type[Client] = Client
    form: type[ClientCreationForm] = ClientCreationForm
    serializer_depth = 0
```

Con esto, tenemos una vista resultante, que acepta los métodos HTTP que
necesitamos, que se comporta como necesitamos, y en caso de que necesitemos
cambiar el comportamiento dentro de un método HTTP, podemos simplemente
reescribir o sobrescribir, o crearlo, así:

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

Espero que este artículo haya sido útil y te ayude a entender cómo crear las
herramientas que puedas necesitar para tus necesidades personalizadas.

[1]: https://docs.djangoproject.com/en/dev/topics/class-based-views/intro/

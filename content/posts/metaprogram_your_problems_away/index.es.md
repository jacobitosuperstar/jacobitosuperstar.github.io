---
title: Metaprograma tus problemas hasta hacerlos desaparecer
date: 2023-09-13T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["python", "metaprogramación"]
categories: ["programación"]
---

La metaprogramación es una herramienta útil cuando quieres incorporar
comportamiento general en tu programa sin tener que agregar código repetitivo
extenso a lo largo de él. Esta práctica típicamente es empleada por individuos
que crean frameworks o herramientas de desarrollo. La idea detrás de la
metaprogramación es proporcionarte una visión inicial de cómo se logran tales
tareas, con la esperanza de inspirar ideas para futuros proyectos de diseño.

Para darle sentido a todos los conceptos discutidos aquí, deberías estar usando
Python versión 3.6 o posterior y tener un entendimiento básico de decoradores,
funciones y clases. En el caso que estamos estudiando, registraremos los
nombres de las funciones llamadas dentro de un programa Python existente.

El logging es una forma de registrar mensajes de nuestro programa, incluyendo
errores, advertencias, información o mensajes de depuración que pueden
colocarse en varios puntos del código. En Python, esto es sencillo. Podemos
crear una clase logger desde el módulo logging para transmitir nuestros
mensajes a la consola, como el que se muestra a continuación.

```python

import logging

class ConsoleLogger:
    def __init__(
        self,
        name: str = "default_logger",
        level:str = "DEBUG"
    ):

          accepted_values = [
              "DEBUG",
              "INFO",
              "WARNING",
              "ERROR",
              "CRITICAL"
          ]

          if level not in accepted_values:
              raise ValueError(
                  "The value given to the variable is not an accepted value."
              )

          logging_level = {
              "DEBUG": logging.DEBUG,
              "INFO": logging.INFO,
              "WARNING": logging.WARNING,
              "ERROR": logging.ERROR,
              "CRITICAL": logging.CRITICAL,
          }

          self.logger = logging.getLogger(name)
          self.logger.setLevel(logging_level[level])

          console_handler = logging.StreamHandler()
          console_handler.setLevel(logging_level[level])

          formatter = logging.Formatter(
              '%(asctime)s - %(levelname)s - %(message)s'
          )
          console_handler.setFormatter(formatter)
          self.logger.addHandler(console_handler)

    def debug(self, message):
        self.logger.debug(message)

    def info(self, message):
        self.logger.info(message)

    def warning(self, message):
        self.logger.warning(message)

    def error(self, message):
        self.logger.error(message)

    def critical(self, message):
        self.logger.critical(message)

if __name__ == "__main__":
    logger = ConsoleLogger()

    logger.debug("This is a debug message.")
    logger.info("This is an info message.")
    logger.warning("This is a warning message.")
    logger.error("This is an error message.")
    logger.critical("This is a critical message.")
```

y solo para aplicarlo a las partes del código que queremos registrar,
escribimos las declaraciones de logging.

```python

class Operations:
    def __init__(x, y):
        self.x = x
        self.y = y

    def add(self):
        logger.debug("add")
        return self.x + self.y

    def subtract(self):
        logger.debug("subtract")
        return self.x - self.y

    def multiply(self):
        logger.debug("multiply")
        return self.x * self.y

    def divide(self):
        logger.debug("divide")
        return self.x / self.y
```

El problema que buscamos abordar es la necesidad de insertar una declaración
de logging en cada sección del código que requiere registro. Este tipo de
repetición de código es precisamente donde brilla la Metaprogramación.

Nuestro encuentro inicial con metaprogramación en Python viene a través de la
utilización de decoradores. Los decoradores son funciones que toman otras
funciones como argumentos y te permiten ejecutar código entre llamadas de
funciones. A menudo los encontrarás en frameworks populares como Django y
Flask. En nuestro caso, aprovecharemos los decoradores para registrar los
nombres de las funciones que llamamos dentro de un mensaje DEBUG.

```python

from typing import Optional, Callable
from functools import wraps, partial


def name_logging_function(
    function: Optional[Callable] = None,
    logger_name: Optional[str] = None,
    logging_level: Optional[str] = None,
) -> Callable:

    if function is None:
        return partial(
          name_logging_function,
          logger_name=logger_name,
          logging_level=logging_level
        )

    def decorator(function):
        @wraps(function)
        def wrapper(*args, **kwargs):
            logger = ConsoleLogger(
                name=logging_name,
                level=logging_level,
            )
            logger.debug(f"{function.__qualname__}")
            return function(*args, **kwargs)
        return wrapper
```

Así es como aplicamos el decorador que acabamos de escribir a los diversos
métodos de la clase. Sin embargo, como notarás, aún no hemos logrado
completamente nuestro objetivo. El código de logging permanece aislado en una
sola ubicación (donde se aplica el decorador). No obstante, simplifica el
proceso para los usuarios porque no necesitan preocuparse por cómo usar el
decorador; simplemente pueden colocarlo en la función donde se necesita.

```python

class Operations:
    def __init__(x, y):
        self.x = x
        self.y = y

    @name_logging_function
    def add(self):
        return self.x + self.y

    @name_logging_function
    def subtract(self):
        return self.x - self.y

    @name_logging_function
    def multiply(self):
        return self.x * self.y

    @name_logging_function
    def divide(self):
        return self.x / self.y
```

Para agilizar aún más el proceso de registrar los nombres de las funciones
llamadas, emplearemos Decoradores de Clase. Un decorador de clase implica
aplicar un decorador a una definición de clase, permitiéndonos aplicar el
decorador de función a todos los métodos dentro de la clase.

```python

def name_logging_class(cls):
    for name, value in vars(cls).items():
        if callable(value):
            setattr(cls, name, name_logging_function(value))
    return cls
```

Con este código, nuestro enfoque implica recibir una definición de clase (cls),
de la cual recuperamos el diccionario de la clase. Luego iteramos a través de
él, verificando si el valor es una función. Si lo es, aplicamos el decorador
de función a ella y posteriormente restablecemos el método decorado de vuelta
en la clase.

```python

@name_logging_class
class Operations:
    def __init__(x, y):
        self.x = x
        self.y = y

    def add(self):
        return self.x + self.y

    def subtract(self):
        return self.x - self.y

    def multiply(self):
        return self.x * self.y

    def divide(self):
        return self.x / self.y
```

Las limitaciones de esta aplicación de decorador son evidentes cuando se trata
de métodos de clase y métodos estáticos. Estos métodos no se verán afectados
porque no son invocables; son objetos descriptores. La única forma en que un
decorador funcionaría con estos métodos es si lo aplicamos como se muestra a
continuación, lo cual difiere de cómo se está aplicando actualmente el
decorador.

```python

class Operations:
    def __init__(x, y):
        self.x = x
        self.y = y

    @classmethod
    @name_logging_function
    def add(self):
        return self.x + self.y

    @staticmethod
    @name_logging_function
    def add(self):
        return self.x + self.y
```

Aunque las cosas se ven más limpias ahora, la repetición de código aún puede
convertirse en un problema cuando nuestro programa contiene numerosas clases.
Además, los decoradores de clase sufren de las mismas limitaciones que
buscábamos superar anteriormente: permanecen aislados en la ubicación donde se
aplican. Si nuestro programa tiene muchas clases, necesitaríamos pasar por cada
una y decorarlas individualmente para darles este comportamiento.

Entonces, ¿cuál es la solución para hacer que estos decoradores sean más
ampliamente aplicables? La respuesta es directa: necesitamos crear una
metaclase. Al crear una metaclase de la cual nuestras clases se derivarán,
podemos cambiar la forma en que se construyen las clases.

Para entender este concepto, es importante saber que todas las clases y objetos
en Python son instancias de `type`. Python tiene un sistema de tipos, y todo
hereda de `type`. Esto implica que, dado que todas las clases son instancias de
`type`, debe haber una clase base de `type` responsable de crear instancias de
`type` en algún lugar del sistema Python.

```log

>>> x = 1
>>> type(x)
<class 'int'>

>>> class A:
...   ...
...
>>> type(A)
<class 'type'>

>>> isinstante(Operations, type)
True>>> x = 1
>>> type(x)
<class 'int'>

>>> class A:
...   ...
...
>>> type(A)
<class 'type'>

>>> isinstante(Operations, type)
True
```

La forma en que se construye una clase en Python, es teniendo el nombre de la
clase, las bases de la clase (clases de las cuales nuestra clase hereda), y el
diccionario que compone la clase (diccionario con todos los métodos y
atributos), y lanzar todo eso en `type`.

```log

Operations = type("Operations", (), clsdict)

# empty class
>>> A = type("A", (), {})
```

Entonces, ¿qué pasa si no queremos usar `type` como nuestro constructor, qué
pasa cuando queremos crear algo con un tipo diferente de `type`? Podemos usar
el argumento de palabra clave metaclass en nuestra definición de clase.

```python

class Operations(metaclass=type):
    ...
```

Para definir una Metaclase típicamente creamos una clase que hereda
directamente de `type` y redefinimos el método `__new__`. El método `__new__`
es el primer método ejecutado en la creación de un objeto de una clase, y es
responsable de crear y devolver la nueva instancia de clase.

```python

class name_logging_metaclass(type):
    def __new__(cls, clsname, bases, clsdict):
        clsobj = super().__new__(cls, clsname, bases, clsdict)
        clsobj = name_logging_class(clsobj)
        return clsobj
```

Aquí estamos redefiniendo el método `__new__` de la metaclase, creando un nuevo
objeto de clase de `type`, y devolviendo ese objeto de clase con el decorador
de clase aplicado a él, finalmente propagando esa funcionalidad de decorador
hacia abajo en las jerarquías. Y con esto, acabamos de cambiar el
comportamiento básico de nuestro programa, sin tener que ir a cada definición y
agregar la declaración de logging.

```python

class Base(metaclass=name_logging_metaclass):
    ...

class Operations(Base):
    def __init__(x, y):
        self.x = x
        self.y = y

    def add(self):
        return self.x + self.y

    def subtract(self):
        return self.x - self.y

    def multiply(self):
        return self.x * self.y

    def divide(self):
        return self.x / self.y
```

Hay muchos problemas que puedes encontrar al intentar hacer esto, por un lado,
la complejidad del programa aumenta dramáticamente, lo cual no es algo que el
gerente de proyecto u otros miembros del equipo quieran manejar, además,
depurar este tipo de código también puede volverse realmente complicado en el
caso de que estemos agregando algo más significativo que solo imprimir nombres
de funciones en la consola, como trabajar con el método `__prepare__` o el uso
de variables no locales a través del proyecto sin ninguna importación.

Al final del día, no hay nada inherentemente malo en mantener el código simple.
Sin embargo, creo firmemente que hay un valor inmenso en que las personas
entiendan y sean capaces de aplicar estas técnicas cuando surja la necesidad.
Toma el ejemplo que hemos discutido: es uno que se puede presentar fácilmente.
En lugar de ir instruyendo a cada programador para que agregue manualmente
logging de consola a cada función que escriben, considera incorporar estos
decoradores o clases base en el núcleo del programa. De esta manera, la
funcionalidad deseada puede propagarse sin esfuerzo a través del proyecto.

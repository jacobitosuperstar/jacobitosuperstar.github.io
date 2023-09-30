---
title: Metaprogram your problems away
date: 2023-09-13T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["python", "metaprogramming"]
categories: ["programming"]
---

Metaprogramming is a useful tool when you want to incorporate general behavior
into your program without having to add extensive boilerplate code throughout
it. This practice is typically employed by individuals who create frameworks or
development tools. The idea behind metaprogramming is to provide you with an
initial insight into how such tasks are accomplished, hopefully inspiring ideas
for future design projects.

To make sense of all the concepts discussed here, you should be using Python
version 3.6 or later and have a basic understanding of decorators, functions,
and classes. In the case we're studying, we will log the names of functions
called within an existing Python program.

Logging is a way to record messages from our program, including errors,
warnings, information, or debugging messages that can be placed at various
points in the code. In Python, this is straightforward. We can create a logger
class from the logging module to stream our messages to the console, like the
one shown below.

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

and just to apply it to the parts of the code that we want to log, we write the
logging statements.

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

The issue we aim to address is the need to insert a logging statement into each
section of the code that requires logging. This type of code repetition is
precisely where Metaprogramming shines.

Our initial encounter with metaprogramming in Python comes through the
utilization of decorators. Decorators are functions that take other functions
as arguments and enable you to execute code between function calls. You'll
often encounter them in popular frameworks like Django and Flask. In our case,
we will leverage decorators to log the names of the functions we call within a
DEBUG message.

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

This is how we apply the decorator we just wrote to the various methods of the
class. However, as you will notice, we haven't completely achieved our goal
yet. The logging code remains isolated to a single location (where the
decorator is applied). Nonetheless, it simplifies the process for users because
they don't need to concern themselves with how to use the decorator; they can
simply place it in the function where it's needed.

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

To further streamline the process of logging the names of called functions, we
will employ Class Decorators. A class decorator involves applying a decorator
to a class definition, enabling us to apply the function decorator to all
methods within the class.

```python

def name_logging_class(cls):
    for name, value in vars(cls).items():
        if callable(value):
            setattr(cls, name, name_logging_function(value))
    return cls
```

With this code, our approach involves receiving a class definition (cls), from
which we retrieve the class dictionary. We then iterate through it, checking
whether the value is a function. If it is, we apply the function decorator to
it and subsequently reset the decorated method back into the class.

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

The limitations of this decorator application are evident when it comes to
class methods and static methods. These methods won't be affected because they
are not callables; they are descriptor objects. The only way a decorator would
function with these methods is if we apply it as demonstrated below, which
differs from how the decorator is currently being applied.

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

Although things are looking cleaner now, code repetition can still become an
issue when our program contains numerous classes. Additionally, class
decorators suffer from the same limitations we sought to overcome earlier: they
remain isolated to the location where they are applied. If our program has many
classes, we'd need to go through each one and decorate them individually to
give them this behavior.

So, what's the solution to make these decorators more broadly applicable? The
answer is straightforward: we need to create a metaclass. By creating a
metaclass from which our classes will be derived, we can change the way classes
are constructed.

To understand this concept, it's important to know that all classes and objects
in Python are instances of `type`. Python has a type system, and everything
inherits from `type`. This implies that, since all classes are instances of
`type`, there must be a base class of `type` responsible for creating instances
of `type` somewhere in the Python system.

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

The way a class is constructed in Python, is by having the name of the class,
the bases of the class (classes from which our class inherits), and the
dictionary that composes the class (dictionary with all methods and
attributes), and throw all that into `type`.

```log

Operations = type("Operations", (), clsdict)

# empty class
>>> A = type("A", (), {})
```

So, what happens if we don’t want to use `type` as our constructor, what
happens when we want to create something with a different kind of `type`. We
can use the metaclass keyword argument in our class definition.

```python

class Operations(metaclass=type):
    ...
```

To define a Metaclass we typically create a class that inherits directly from
`type` and redefine the `__new__` method. The `__new__` method is the first
method run in the creation of an object of a class, and is responsible for
creating the and returning the new class instance.

```python

class name_logging_metaclass(type):
    def __new__(cls, clsname, bases, clsdict):
        clsobj = super().__new__(cls, clsname, bases, clsdict)
        clsobj = name_logging_class(clsobj)
        return clsobj
```

Here we are redefining the `__new__` method of the metaclass, by creating a new
class object from `type`, and returning that class object with the class
decorator applied to it, finally propagating that decorator functionality down
hierarchies. And with this, we just changed the basic behavior of our program,
without having to go into every definition and add the logging statement.

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

There are a lot of problems that you may encounter by trying to do this, for
one, the complexity of the program rises dramatically, which is not something
that the project manager or other members of the team want to deal with, also,
debugging this type of code can also become really complicated in the case we
are adding something more significant than just printing function names into
the console, like working with the `__prepare__` method or the use of non local
variables across the project without any imports.

At the end of the day, there's nothing inherently wrong with keeping code
simple. However, I firmly believe that there's immense value in individuals
understanding and being able to apply these techniques when the need arises.
Take the example we've discussed – it's one that can be easily presented.
Instead of going around instructing every programmer to manually add console
logging to each function they write, consider incorporating these decorators or
base classes into the core of the program. This way, the desired functionality
can effortlessly propagate throughout the project.

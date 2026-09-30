---
title: De parejas a soltero. Microservicios como objetos
date: 2026-09-27
draft: false

read_more: Leer más...
tags: ["python", "go", "Diseño", "microservicios", "microkernel"]
categories: ["programación"]
---

Después de que mi novia me terminara, recuperé mucho tiempo que antes le
dedicaba, así que empecé a pensar en los límites de nuestra relación, en los
problemas de comunicación y en los patrones que, en lugar de mantenernos como
dos personas distintas, nos convirtieron en una sola masa que simplemente está
en dos lugares al mismo tiempo. Y entonces me llegó la idea: debería estar
usando una arquitectura distinta a los microservicios para sistemas que tienen
diseños parecidos.

Como muchos de ustedes, me he encontrado con sistemas que se van por el camino
de los microservicios buscando distribuir el trabajo, pero que siguen teniendo
la aplicación principal como único punto de falla, con nodos cuyo tráfico es
proporcional al del proceso principal que distribuye ese trabajo. En el caso que
vamos a analizar, la aplicación principal hace solo I/O, sus microservicios
también hacen un montón de I/O, y esos microservicios dependen únicamente del
tráfico de la aplicación principal. Es decir, el microservicio se comporta como
una subrutina.

Por específico que suene, son sistemas muy comunes. La idea de esa solución es
mantener el único punto de falla lo más simple posible y descargar el trabajo en
los distintos microservicios que componen el sistema. Así que me puse a pensar:
¿son los microservicios la respuesta para un sistema así?, ¿lo es el monolito
modular?, ¿o hay otros diseños que podamos revisar para atacar este tipo de
problemas?

Siempre hay que definir cuáles son los límites entre dos dominios, y hasta qué
punto y cómo necesitan estar separados. Hay casos donde **los microservicios son
la única opción**, como cuando necesitamos codificar video, procesar imágenes o
hacer alguna otra tarea pesada en CPU. O cuando una pieza de lógica tiene que
ser usada por varios sistemas al mismo tiempo, y el límite entre una librería y
un servicio está claramente definido, porque ese servicio requiere un entorno,
un lenguaje, un modelo de seguridad, etc., distintos. **Haciendo la red parte
del problema en lugar del sobrecosto que lo rodea**.

## EL PROBLEMA

Como siempre, yo. Pero para todo lo demás, lo primero en lo que hay que pensar
es en qué es lo que realmente se está tratando de resolver, y hay dos cosas que
quiero atacar.

1. La red. Cuando descargamos el trabajo del programa principal a sus
   microservicios, le agregamos la latencia de una ida y vuelta a cada
   respuesta, y le sumamos la fragilidad de las conexiones de red a los procesos
   principales de nuestro sistema.

2. Eficiencia y costos. Cuando empezamos a levantar trabajadores que dependen
   directamente del tráfico de nuestro servicio principal, estamos agregando más
   contenedores de los que se necesitan para resolver un problema. Eso hace que
   el problema requiera más recursos para su solución y, con los costos de
   alquilar infraestructura cada vez más altos, hay que pensar cuántos puntos de
   las ganancias se van en ella.

## RESTRICCIONES DEL CÓDIGO

La idea principal de esta implementación es conservar la mayor cantidad posible
del código de los microservicios. Es decir, aunque puede haber formas más
eficientes de programar este tipo de soluciones, el punto es hacer una
transición, principalmente reescribir el adaptador entre el proceso principal y
el microservicio, de forma tal que, podamos deshacernos de la llamada de red sin
tener que cambiar la lógica actual, ni del microservicio, ni de la aplicación
principal.

## PENSANDO EN NUEVAS IDEAS

Los microservicios, en este sentido, nos dan varias ventajas que tenemos que
tener en cuenta al evaluar una solución, y son estas:

1. Aislamiento operativo. Cuando un proceso de un microservicio no logra
   arrancar, es solo un trabajador que no arrancó. No toda la aplicación.

2. Escalado independiente cuando el tráfico es mixto y desigual.

3. Diseño de plugins. Podemos agregar y enrutar distintas partes del sistema a
   distintos trabajadores. Por ejemplo, si necesitamos dos del mismo trabajador
   con configuraciones distintas, como un trabajador que envía correos a A y
   otro que envía correos a B, es solo un condicional de enrutamiento y tenemos
   dos del mismo trabajador cumpliendo propósitos distintos.

Y pensé, después de toda la autorreflexión y la autosanación que hice mientras
lloraba, que existe un diseño de sistema que cubre estas cosas sin necesidad de
mandar esas cargas de trabajo por la red.

Me vinieron a la mente dos arquitecturas.

**Microkernel**, en el sentido de que tenemos una aplicación núcleo mínima que
es dueña del transporte, el enrutamiento, los errores y la observabilidad, más
unos plugins que son dueños del comportamiento del dominio.

**Arquitectura hexagonal**, que es lo que tenemos actualmente, pero en lugar de
dejar los adaptadores sobre la red, crearíamos la interfaz en la aplicación
principal que interactúa con cada uno de los objetos que estamos corriendo.

La arquitectura de monolito modular, como se entiende normalmente, es un gran
bloque con todos estos componentes inicializados juntos, donde cada uno de los
dominios bien definidos tiene una API que el proceso principal llama. Eso no es
suficiente para nuestra implementación, así que se le agrega un enfoque tipo
microkernel para lograr el diseño de plugins y el aislamiento operativo.

Para lograr esto pensé en objetos que contienen la lógica del microservicio, que
pueden cargar un estado (como una conexión continua a una base de datos,
credenciales de autenticación y cosas así) mientras ejecutan los mismos pasos
lógicos que hacía el microservicio. Y en caso de falla, tendrían su propia
lógica de reintento en otro lado, y si llega una llamada del proceso principal,
vamos a devolver rápidamente un error de no disponible, sin dejar que el sistema
se sobrecargue ni gaste ciclos en procesos que no arrancan.

## EL DISEÑO

Para la migración del monolito distribuido a esto, pensé en tres partes: la
aplicación principal, la interfaz entre la aplicación principal y los objetos, y
los objetos, cada uno con la lógica de un microservicio. La interfaz es lo único
que tienen en común la aplicación principal y el código de los objetos. La
aplicación enruta los trabajos a través de esa interfaz, cada objeto registrado
(el antiguo microservicio) se inicializa, y luego se carga en esa interfaz.

```
┌──────────────────────────────────────────────────────────┐
│                    SISTEMA PRINCIPAL                     │
│                                                          │
│  ┌─────────┐        ┌───────────┐        ┌───────────┐   │
│  │         │ llama  │           │alimenta│   MICRO   │   │
│  │   API   │───────▶│ INTERFAZ  │◀───────│ SERVICIOS │   │
│  │         │        │           │        │ (objetos) │   │
│  └─────────┘        └───────────┘        └───────────┘   │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

Para la interfaz, el diccionario es la estructura más flexible para guardar
cosas así, porque podemos definir la llave que enruta a ese objeto y, como
valor, podemos tener un tipo opcional, de modo que esa llave puede devolver el
objeto que representa al microservicio o NULL. Y las llaves son strings que
podemos modificar, crear o cambiar como nos parezca. Además se parecen al string
que guarda la URL del microservicio, así que la idea es tener esto por si hay
mecanismos de enrutamiento parecidos, principalmente que funcionen a través de
la manipulación de strings.

Dos diccionarios componen los objetos registrados. Uno guarda los objetos que se
inicializaron con éxito y están funcionando. El otro guarda los objetos que no
lograron inicializarse, o que fallan después de inicializarse, como un objeto
que intenta conectarse a una base de datos no disponible después del arranque.
Ese segundo diccionario tiene la lógica que reintenta su inicialización en
distintas etapas de la aplicación (backoff exponencial u otra estrategia que les
parezca), completamente independiente de sus llamadas dentro del proceso. Así
podemos devolver respuestas fallidas rápidamente sin sobrecargar el sistema con
evaluaciones por cada petición.

Entre los dos, esos diccionarios guardan todos los objetos que la apliación usa,
reemplazando los microservicios.

Por la red nunca recibimos una excepción de un microservicio, recibíamos un
status. La interfaz mantiene ese contrato, así que la respuesta de un trabajador
es un valor. Tres resultados son suficientes:

```python
from dataclasses import dataclass
from enum import Enum
from typing import Protocol

class Outcome(Enum):
    OK     = "ok"       # el trabajo está hecho
    ERROR  = "error"    # esta petición falló, el trabajador está bien
    BROKEN = "broken"   # el trabajador no puede trabajar, sácalo del diccionario

@dataclass
class Answer:
    outcome: Outcome
    body:    dict | None = None
    status:  int  | None = None   # para ERROR, el status que mandaba el microservicio
    detail:  str  | None = None

# lo que el núcleo necesita de cualquier trabajador. Nada de cómo lo hace.
class Worker(Protocol):
    def start(self) -> Answer: ... # conectarse, autenticarse, calentar
    def handle(self, operation: str, request: dict) -> Answer: ...

REGISTRY:    dict[str, Worker] = {}   # funcionando
UNAVAILABLE: dict[str, Worker] = {}   # rotos, el supervisor los está reintentando
```

El diccionario se podría construir desde la configuración, por si necesitamos
cargar distintos tipos de trabajadores en distintas instancias, o con objetos
que se auto-registran al momento de inicializarse. Si hay un objeto que
representa un microservicio que no se está usando, no es un problema, porque el
objeto solo se quedaría en memoria sin hacer nada, pero no es difícil
implementar un evaluador, solo para asegurarnos de cargar únicamente los objetos
que vamos a usar.

```python
def build_registry(config):
    for key, spec in config["routes"].items():
        kind = KNOWN_KINDS.get(spec["kind"])
        if kind is None:
            raise SystemExit(f"unknown kind: {spec['kind']}")   # error de configuración, parar
        worker = kind(spec["settings"])
        target = REGISTRY if worker.start().outcome is Outcome.OK else UNAVAILABLE
        target[key] = worker

    missing = config["required_keys"] - REGISTRY.keys() - UNAVAILABLE.keys()
    if missing:
        raise SystemExit(f"routes without a worker: {missing}")
```

Y la ruta se vuelve una búsqueda y una llamada, la misma forma que tenía cuando
el trabajador era una llamada de red, que es justamente el punto:

```python
async def route(request):
    key    = key_of(request)
    worker = REGISTRY.get(key)
    if worker is None:
        return 503

    answer = await asyncio.to_thread(worker.handle, request.operation, request)

    if answer.outcome is Outcome.BROKEN:
        move(key, REGISTRY, UNAVAILABLE)   # la siguiente petición ni lo intenta
        return 503
    if answer.outcome is Outcome.ERROR:
        return answer.status               # el trabajador está bien, esta petición no
    return answer.body
```

Cada falla sobre la que el núcleo tiene que actuar llega como un valor que puede
leer. Las excepciones se quedan dentro de cada objeto, donde las lanzan las
librerías.

Dos trabajadores del mismo tipo con configuraciones distintas ahora son una
segunda entrada en el diccionario, no otro elemento para desplegar:

```
routes:
  "notify.a" : { kind: "email", settings: { provider: A } }
  "notify.b" : { kind: "email", settings: { provider: B } }
```

### El aislamiento es una propiedad del objeto, no del proceso (doble sentido)

Si un objeto falla, ya sea durante la inicialización o dentro del proceso, lo
único que necesitamos agregar es el mecanismo de seguridad que lo mueve al
registro de no disponibles y reintenta su inicialización desde ahí. Cuando las
peticiones hagan la búsqueda, obtendrán un NULL -> 503 de inmediato, sin tumbar
la aplicación.

El objeto es el único que sabe cuáles de sus fallas son normales y cuáles
significan que ya no puede trabajar:

```python
class Email:
    def start(self):
        try:
            self.connection = connect(self.settings)
            return Answer(Outcome.OK)
        except (ConnectionError, AuthError) as error:
            return Answer(Outcome.BROKEN, detail=str(error))

    def handle(self, operation, request):
        try:
            return Answer(Outcome.OK, body=self.run(operation, request))
        except NotFound:
            return Answer(Outcome.ERROR, status=404)             # esperado, normal
        except (ConnectionError, AuthError) as error:
            return Answer(Outcome.BROKEN, detail=str(error))     # no puedo trabajar
        except Exception as error:
            return Answer(Outcome.ERROR, status=500, detail=str(error))  # un bug, no una caída
```

Nada sale de `handle` como excepción. El último `except` es lo mismo que hacía
antes un servidor: un error que no esperaba se volvía un 500, y el proceso
seguía atendiendo.

Cuando uno de los objetos está roto, simplemente pasa a manos de un supervisor
que corre una reinicialización con backoff exponencial, para poder devolverlo al
router cuando esté disponible, pero también para no gastar demasiados recursos
en caso de que nunca se recupere.

```python
async def supervisor():
    delay    = {}   # llave -> segundos hasta el próximo intento, se duplica en cada falla
    retry_at = {}   # llave -> cuándo volver a intentar
    while True:
        for key, worker in list(UNAVAILABLE.items()):
            if time.monotonic() < retry_at.get(key, 0):
                continue
            if (await asyncio.to_thread(worker.start)).outcome is Outcome.OK:
                move(key, UNAVAILABLE, REGISTRY)
                delay.pop(key, None)
                retry_at.pop(key, None)
            else:
                delay[key]    = min(delay.get(key, 0.5) * 2, 300)   # backoff exponencial
                retry_at[key] = time.monotonic() + delay[key]
        await asyncio.sleep(1)


def move(key, source, target):
    worker = source.pop(key, None)
    if worker is not None:
        target[key] = worker
```

`worker.start()` también es código bloqueante, así que el supervisor también
pasa por un hilo. Un trabajador que se está reconectando no puede frenar el loop
de todos los demás.

`move` no necesita un lock. Solo `route` y el supervisor tocan los diccionarios,
y los dos corren en el event loop, un paso a la vez. Los hilos solo corren
`handle` y `start`.

### Límites claros, como en una relación, también deben existir entre los dominios

La llevé a la tumba de mi papá... En fin. La aplicación principal y los objetos
no tienen que compartir un modelo de concurrencia, porque nunca se tocan. La
interfaz está entre los dos, y cómo corren los trabajos es parte de su dominio,
como todo lo demás que tiene que ver con los microservicios. La aplicación
principal llama a la interfaz en su propio modelo, y la interfaz corre cada
trabajo en el suyo. Así podemos dejar el código completamente intacto y hacer
que la interfaz se encargue de traducir entre los dos.

En mi caso, la aplicación principal era Python asíncrono (FastAPI) y los
microservicios eran código bloqueante (clientes síncronos), así que cada trabajo
de un microservicio tiene que pasar por `asyncio.to_thread` para poder correr
sin bloquear la aplicación principal.

Este puente existe porque Python tiene dos modelos de concurrencia que no se
mezclan, el código asíncrono y el código bloqueante. Un lenguaje con un único
modelo de concurrencia nativo, como Go o Erlang, no necesita este tipo de capa
de traducción entre los dominios.

La traducción no es gratis. En mis mediciones, una llamada a un objeto costaba
0,065 ms de CPU y el trabajo dentro de ella solo 0,018 ms; el resto era el salto
al hilo y de vuelta. Aun así es una décima parte de los 0,69 ms que costaba la
misma llamada por gRPC [^2].

Como el pool de hilos corre varias llamadas del mismo objeto al mismo tiempo, el
objeto es compartido. Eso es seguro siempre y cuando el objeto no cambie después
del arranque: todo lo que pertenece a una petición vive en los parámetros y en
las variables locales de `handle`, nunca en el objeto.

## COSTOS

### No me estoy engañando solo si los costos me dan la razón

Olvídense de mi ex, nunca la amé. El punto de todo esto es un sistema más
simple, que solo tiene un poco más de "creatividad" en la capa de interfaz, con
el bonus de que es más barato de correr. Donde comen dos, come uno, si
comprenden a lo que quiero llegar. Es obvio.

Cada llamada que cruza el límite entre los dominios cuesta tiempo: serializar,
cruzar un socket, deserializar, agendarse en un segundo runtime, y lo mismo otra
vez de vuelta. Pero además, si el tráfico del pod del microservicio depende solo
de las llamadas del proceso principal, ese pod nunca está lleno. Pagas por esa
capacidad sobrante. En un solo contenedor el mismo trabajo escala como una sola
unidad, y la CPU y la RAM se mueven entre las partes del sistema a medida que se
mueve el tráfico.

**Las peticiones por pod suben cuando separas**, porque parte del trabajo fue
delegado. Cualquiera que mida eso va a concluir que la separación es más rápida.
La medida real es el **costo por petición**: segundos de CPU y bytes de memoria
para la misma unidad de **trabajo**.

Los siguientes números representan una aplicación hecha con FastAPI que descarga
trabajo en distintos pods. Para poner a los microservicios en su mejor
escenario, vamos a asumir que todas las peticiones que llegan a la aplicación
principal se delegan no a varios microservicios sino a uno solo, en la misma
red, en la misma máquina.

Ayuda ver qué partes de una petición cuestan qué, y cuáles de esas partes puede
eliminar la arquitectura. Son milisegundos de CPU para una petición, medidos en
una máquina [^1].

| parte de la petición                                                    | ms    | ayuda una CPU más rápida | la separación lo agrega       |
| ----------------------------------------------------------------------- | ----- | ------------------------ | ----------------------------- |
| el trabajo: parsear, validar, la lógica del dominio, armar la respuesta | 4,00  | sí                       | no, es igual en los dos casos |
| el salto, CPU: serializar, deserializar, despertar dos schedulers       | ~0,76 | sí                       | sí                            |
| el salto, tránsito: el kernel y el cable                                | ~0,10 | **no**                   | sí                            |

**Con una CPU más rápida** las dos primeras filas se encogen. La tercera no. Un
socket, una llamada al sistema y el despertar de un scheduler toman el tiempo
que toman.

**Juntar todo** elimina la segunda y la tercera fila. La primera se queda
exactamente igual, porque es el trabajo a realizar. Son 0,86 ms menos de CPU en
cada petición, y cerca de 1 ms menos de tiempo de respuesta: a 200 peticiones
por segundo la mediana pasó de 6,0 ms a 4,8 ms, y a 250 de 5,9 ms a 4,9 ms.
Además, ese salto en Python parece demasiado pequeño como para tenerlo en
cuenta, pero si se usara un lenguaje más rápido, ese salto podría durar tanto
como el trabajo que realmente necesitamos hacer. Es como decirle a tu pareja que
vas a estar ahí, y luego desconectarte de todo el mundo, sobre todo de ella, por
trabajar, porque estás tratando de tener una carrera, o algo así.

### Déjame terminar el argumento, no seas como ella

Lo único que necesitas es cuántas peticiones por segundo responde un pod en su
límite, para cada forma. Los números de Python vienen de la misma máquina de
antes [^1]. Los valores de Go son un ejemplo ilustrativo de otro sistema con la
misma forma: una aplicación principal que hace I/O y le pasa cada petición a un
microservicio que también hace I/O, y cuyo tráfico viene solo de la aplicación
principal. No es la misma aplicación que la de Python, así que los números son
más ilustrativos que cualquier cosa.

```
                     Python (FastAPI)        Go (ilustrativo)
servicio principal   350 req/s               2.750 req/s
microservicio        500 req/s               3.900 req/s
servicio unido       250 req/s               2.500 req/s
```

Para el cálculo de infraestructura, redondeas hacia arriba una vez por la
aplicación principal, y una vez más por cada microservicio entre los que divides
el trabajo.

```
pods unido    = ceil(R / unido)
pods separado = ceil(R / principal) + n * ceil((R / n) / microservicio)
```

Con un solo microservicio, `n` es 1 y el segundo término es simplemente
`ceil(R / microservicio)`, porque todo el tráfico va a él.

#### Python

| Req/s     | unido | separado      | costo adicional |
| --------- | ----- | ------------- | --------------- |
| 100/s     | 1     | 2 (1+1)       | +100%           |
| 1.000/s   | 4     | 5 (3+2)       | +25%            |
| 2.000/s   | 8     | 10 (6+4)      | +25%            |
| 3.000/s   | 12    | 15 (9+6)      | +25%            |
| 4.000/s   | 16    | 20 (12+8)     | +25%            |
| 5.000/s   | 20    | 25 (15+10)    | +25%            |
| 10.000/s  | 40    | 49 (29+20)    | +22%            |
| 100.000/s | 400   | 486 (286+200) | +22%            |

#### Go

| Req/s     | unido | separado   | costo adicional |
| --------- | ----- | ---------- | --------------- |
| 100/s     | 1     | 2 (1+1)    | +100%           |
| 1.000/s   | 1     | 2 (1+1)    | +100%           |
| 2.000/s   | 1     | 2 (1+1)    | +100%           |
| 3.000/s   | 2     | 3 (2+1)    | +50%            |
| 4.000/s   | 2     | 4 (2+2)    | +100%           |
| 5.000/s   | 2     | 4 (2+2)    | +100%           |
| 10.000/s  | 4     | 7 (4+3)    | +75%            |
| 100.000/s | 40    | 63 (37+26) | +57%            |

#### Python, con cuatro microservicios

Las dos tablas de arriba dividen el trabajo en dos. Ahora pártelo en cuatro, que
es lo que pasa cuando los límites de los dominios siguen la [ley de Conway][1]
en lugar del tráfico. La aplicación principal recibe las peticiones y enruta
cada una al microservicio dueño de ese tipo de trabajo. Una petición sigue
cruzando un solo límite, así que el costo de una petición no cambia.

| Req/s    | cada microservicio recibe | unido | separado, cuatro microservicios | costo adicional |
| -------- | ------------------------- | ----- | ------------------------------- | --------------- |
| 100/s    | 25/s                      | 1     | 5 (1 + 4x1)                     | +400%           |
| 1.000/s  | 250/s                     | 4     | 7 (3 + 4x1)                     | +75%            |
| 10.000/s | 2.500/s                   | 40    | 49 (29 + 4x5)                   | +22%            |

A 1.000 peticiones por segundo cada microservicio recibe 250. Entre todos
necesitan dos pods de capacidad y alquilas cuatro, porque un microservicio no
puede tener medio pod. A 100 por segundo necesitan una quinta parte de un pod y
aun así alquilas cuatro. A 10.000 el costo adicional es el mismo que cuando se
divide en un solo microservicio.

### De dónde sale el costo adicional

Un pod es indivisible, así que el sobrante es capacidad que alquilas y nunca
usas, y de eso está hecho el costo adicional. Por eso hay puntos en las tablas
donde el costo extra de la infraestructura parece bajar.

Lo que importa es dónde deja de ser desperdicio. Así que en lugar de contar
pods, cuenta qué tanto de cada pod lleva tráfico. A 100 peticiones por segundo
el pod de un microservicio está ocupado al 20% y los de cuatro al 5%, y eso es
todo el +100% y el +400%. A 1.000 los cuatro microservicios siguen medio
ociosos. Luego, a 10.000, todos los pods de ambos lados están llenos, o a menos
de un 2% de estarlo, tanto con un microservicio como con cuatro, y la separación
sigue costando un 22% más, que vendría a representar el salto entre los
dominios, es decir, serialización, deserialización y tiempo de la petición en la
red.

Cada celda es la parte de la capacidad que alquilas que está ocupada.

| Req/s    | forma separada        | pods unido | pods principal | pods microservicio | costo adicional |
| -------- | --------------------- | ---------- | -------------- | ------------------ | --------------- |
| 100/s    | un microservicio      | 40%        | 29%            | 20%                | +100%           |
| 100/s    | cuatro microservicios | 40%        | 29%            | 5%                 | +400%           |
| 1.000/s  | un microservicio      | 100%       | 95%            | 100%               | +25%            |
| 1.000/s  | cuatro microservicios | 100%       | 95%            | 50%                | +75%            |
| 10.000/s | un microservicio      | 100%       | 98%            | 100%               | +22%            |
| 10.000/s | cuatro microservicios | 100%       | 98%            | 100%               | +22%            |

## AISLAMIENTO SIN LA RED

### Como hice de mi novia mi vida, ya no tengo amigos

El aislamiento de procesos por sí solo no necesita separación de red, porque el
problema del aislamiento es totalmente distinto al de la distribución, y
completamente distinto al del escalado. Y aunque lo sabemos desde finales de los
60, lo que queda en nuestro conocimiento colectivo son las implementaciones
populares, contenedores y microservicios, no las ideas detrás de ellas. Al fin y
al cabo, seguimos usando una arquitectura hexagonal.

La idea es vieja y nunca se trató únicamente de máquinas distribuidas. Un
**microkernel** mantiene un núcleo mínimo que es dueño del transporte, el
enrutamiento y los errores, y pone el comportamiento del dominio en plugins que
el núcleo carga, rechaza y reemplaza. La palabra proceso está por todas partes
en esa literatura, desde el núcleo de Brinch Hansen en 1969, pero la parte que
tomamos prestada no es el espacio de direcciones separado. Es el aislamiento
dentro de un solo programa: una pieza que puede fallar, salir del diccionario y
reintentarse sin que el núcleo se caiga con ella.

**Erlang con OTP** (Open Telecom Platform) es una implementación de esa idea, y
la que la llevó más lejos. Árboles de supervisión, reinicio independiente y
aislamiento de fallas, con procesos que viven dentro de una sola máquina virtual
y cuestan microsegundos en crearse. Un supervisor que vuelve a poner en marcha
un trabajador caído es la misma historia operativa que un contenedor que se
vuelve a agendar, sin un socket en el medio. Funciona así desde mediados de los
noventa.

## CONCLUSIÓN

### Ahora todo es diferente, he cambiado, lo prometo

Después de la migración, vale la pena decir algunas cosas sobre el programa
resultante.

**La aplicación principal no tuvo ningún cambio en comportamiento.** Su código
no cambió. Sigue pidiendo un trabajo y recibiendo las mismas respuestas que
recibía antes, porque la interfaz se encarga de todo lo que antes hacía la red,
y devuelve lo que antes devolvía el microservicio.

**Los números.** En mi sistema, una aplicación principal y tres microservicios,
esto es lo que cambió al unirlos:

| medido                                      | separado | unido    |
| ------------------------------------------- | -------- | -------- |
| contenedores                                | 4        | 1        |
| memoria después del arranque                | ~425 MB  | ~130 MB  |
| CPU de una llamada a un microservicio       | 0,69 ms  | 0,065 ms |
| tiempo de una llamada a un microservicio    | 2,5 ms   | 0,06 ms  |
| mediana del tiempo de respuesta a 200 req/s | 6,0 ms   | 4,8 ms   |
| pods para 1.000 req/s (un microservicio)    | 5        | 4        |

Las filas de las llamadas vienen del benchmark de la sección de concurrencia
[^2]. El resto viene de la misma máquina de la sección de costos [^1].

Ahora hay **simplificación** en varios frentes. **Despliegue**, porque ahora
tenemos varios contenedores menos de los cuales preocuparnos. **Pruebas**, que
se volvieron más fáciles, porque las complejas pruebas de integración entre
contenedores, más las pruebas unitarias de cada implementación, se volvieron
solo pruebas unitarias. **Desarrollo**, porque cuando hay que actualizar o
cambiar un servicio, ya no hace falta el paso de generar los protobuf y
actualizarlos en las distintas aplicaciones. **Costos**, porque ya no pagamos
por infraestructura subutilizada, y hay una relación más clara entre los
clientes que atendemos y los costos de nuestra infraestructura.

Y en cuanto a la plata, la separación cuesta al menos un 22% más que la
aplicación unida, y ese es el mínimo, ya que esta prueba se hizo en
circunstancias ideales. Si nuestro I/O tarda más que un instante, esas
corrutinas/hilos se quedan abiertos, consumiendo memoria extra, y nuestro
sistema tiene que escalar no solo por su uso de CPU sino también por su uso de
RAM, lo que empuja la proyección hacia más costos.

## CÓMO MEDIR TUS PROPIOS NÚMEROS

No necesitas un profiler. Necesitas el mismo trabajo corrido de las dos formas,
y un generador de carga que empuje cada pod hasta que deje de responder más:

```
unido          = peticiones por segundo que responde un pod unido en su límite
principal      = peticiones por segundo que responde un pod principal en su límite,
                 con suficientes pods de microservicio detrás para que no sean el cuello de botella
microservicio  = peticiones por segundo que responde un pod de microservicio en su límite
```

Dos advertencias. Mide cerca de la saturación, porque el procesador baja su
frecuencia cuando la máquina está tranquila, y la misma petición parece dos o
tres veces más cara. Y mide las dos formas en la misma máquina el mismo día, o
estarás comparando el clima.

[^1]:
    Intel i5-4570 a 3,4 GHz, un núcleo y 512 MiB por contenedor, Python 3.14. Si
    tu núcleo es el doble de rápido, divide las dos filas de CPU entre dos. La
    fila de tránsito no se mueve. Todo aquí corre como contenedores en esa única
    máquina, así que la fila de tránsito es la interfaz de loopback. En
    producción los dos procesos están en nodos distintos y esa fila pasa a ser
    de 0,5 a 3 milisegundos. Casi no cuesta CPU, así que apenas mueve el conteo
    de pods, pero sí cambia cuántas peticiones están en vuelo al mismo tiempo
    (tasa por latencia), así que un cable más lento necesita más espacios de
    concurrencia, y eventualmente más pods, para el mismo tráfico.

[^2]:
    La misma máquina, pero usando sus cuatro núcleos. El cliente y el servidor
    gRPC corrían en un solo proceso, con OpenTelemetry en ambos lados, así que
    los 0,69 ms son la CPU de los dos lados juntos, y los 2,5 ms no son el
    tiempo entre dos contenedores. Los 0,018 ms son solo la lógica del dominio
    de una llamada.

[1]: https://es.wikipedia.org/wiki/Ley_de_Conway

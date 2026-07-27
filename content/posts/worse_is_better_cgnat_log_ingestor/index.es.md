---
title: '"Peor es Mejor", construyendo un ingestor de logs CGNAT en Go'
date: 2026-07-03T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["go", "SQLite", "Kafka", "Arquitectura", "CGNAT"]
categories: ["programación"]
---

Richard Gabriel escribió un ensayo con el nombre _The Rise of Worse is Better_.
El ensayo dice que un sistema simple que hace la mayoría del trabajo necesario
es mejor en operación que un sistema completo, correcto y complejo. La cultura
startup mostró que esta idea es correcta. Es mejor salir al mercado temprano
con una buena idea en condición parcial, y después hacer un producto completo.
Es peor llegar tarde con el producto perfecto.

Al mismo tiempo, las grandes empresas de crecimiento nos dieron la idea
opuesta. Esta idea dice que cada sistema debe escalar sin límites. Desde su
primer día, el diseño debe estar listo para un flujo ilimitado de funciones y
para el crecimiento horizontal. Para mí, el resultado es software malo,
dividido entre cada producto que un proveedor de nube te puede vender.

Este artículo muestra un ingestor de logs de CGNAT. Según las ideas actuales
del diseño de software, este ingestor es "peor". Con este ingestor, quiero
examinar la idea de que una solución para los problemas de hoy, y no para los
de mañana, es deuda técnica. También quiero mostrar cómo controlar los
problemas que causa un diseño simple.

## El problema

Carrier-Grade NAT (CGNAT) es el método con el que un ISP pone miles de
suscriptores detrás de un grupo pequeño de direcciones IPv4 públicas. Cada
dispositivo CGNAT escribe un mensaje de log por cada evento de una sesión:
creación, sustain periódico y liberación. Los operadores de la red deben
responder una pregunta rápido: ¿qué suscriptor estaba detrás de esta dirección
IP pública y este puerto un momento antes? Los operadores deben tener los
mismos datos en tres direcciones: por dirección pública y puerto, por dirección
privada y puerto, y por suscriptor.

Tres propiedades de esta carga de trabajo controlan cada decisión posterior del
diseño:

- **Una tasa de escritura muy alta**: Decenas de miles de mensajes de log
  llegan cada segundo por syslog, continuamente.
- **Una retención muy corta**: Un mapeo es importante solo por minutos. La
  función del sistema es mostrar la actividad de la red en tiempo real.
- **Lecturas de lo más reciente**: Cada búsqueda debe encontrar el mapeo más
  reciente para una llave.

## El primer diseño

Mi primera idea fue un sistema distribuido. Este sistema recibe un flujo
secuencial de logs y divide el trabajo entre muchos procesadores paralelos.

Para diseñar el sistema, seguí un registro de CGNAT por cada paso del proceso:

```
 Carrier SysLog -> receiver -> parse -> storage <- query api <- user
```

Para un registro, examiné cada parte del proceso, una parte después de la otra.
No pensé en los modelos de concurrencia en este punto, porque la operación no
determinista hace difícil el análisis.

Después hice el análisis otra vez con dos registros, para encontrar las partes
comunes de los dos procesos. Los dos registros tienen dos puntos comunes. El
primer punto es el receptor, porque todos los mensajes llegan ahí en secuencia,
a máxima velocidad. El segundo punto es el almacenamiento, porque todos los
mensajes de la ventana actual de Time-To-Live (TTL) están ahí al mismo tiempo.

Este análisis me mostró las dos estructuras de datos que tenía que seleccionar
correctamente. El receptor debe enviar cada mensaje hacia adelante y volver al
socket inmediatamente. Un datagrama que llega cuando el receptor no está listo
es un datagrama perdido. Por eso la primera estructura es una cola acotada. La
cola retiene las ráfagas. La cola también desconecta la velocidad de llegada de
la velocidad del trabajo de parseo.

La segunda estructura es para el almacenamiento. El número de registros es más
grande que el número de escrituras que una base de datos puede hacer. Por eso
una estructura de colección debe agrupar los registros en lotes.

Estas dos estructuras dividen el software en dos partes principales. El
ingestor debe hacer el mínimo trabajo posible. El escritor debe parsear los
datos y preparar los datos para la base de datos.

## El diseño complejo

Durante el diseño, llegó la pregunta usual: ¿cómo escala la solución? El
receptor debe recibir los mensajes UDP en secuencia. Por eso el receptor es el
cuello de botella principal del rendimiento. Todo el otro trabajo pasa por
colas. Escritores diferentes pueden leer de partes diferentes de la cola. Así
el trabajo serializado se vuelve escalable horizontalmente.

El sistema entonces tiene esta estructura:

```
             CGNAT devices (syslog UDP)
                          │
                          ▼
                 ┌─────────────────┐
                 │    receiver     │  receive · no parse · produce
                 └────────┬────────┘
                          ▼
                 ┌─────────────────┐
                 │      Kafka      │  raw lines · N partitions
                 └────────┬────────┘
             ┌────────────┼────────────┐
             ▼            ▼            ▼
        ┌─────────┐  ┌─────────┐  ┌─────────┐
        │ writer  │  │ writer  │  │ writer  │  parse · batch · write
        └────┬────┘  └────┬────┘  └────┬────┘  (one per partition)
             └────────────┼────────────┘
                          ▼
                 ┌─────────────────┐
                 │   wide-column   │  one table per query axis
                 │      store      │  windowed compaction · TTL
                 └────────┬────────┘
                          ▼
                 ┌─────────────────┐
                 │    query API    │  the three lookup axes
                 └────────┬────────┘
                          ▼
                       clients
```

Cada parte del sistema tiene una función. Kafka es el buffer que retiene las
ráfagas cuando el almacén está lento. Kafka también da replay de los mensajes
cuando un escritor falla. Las particiones controlan la escala: más particiones
y más escritores dan más throughput. El consumer group da recuperación después
de una falla, sin código de coordinación. A escala completa, este diseño puede
recibir el tráfico completo de un carrier grande: más de 1.000.000 de mensajes
por segundo.

Para el almacenamiento, seleccioné Cassandra, porque su diseño es exactamente
para este tipo de carga de trabajo. Una base de datos distribuida de columnas
anchas divide los datos por llave a través del clúster. Así la capacidad de
escritura aumenta cuando agregas nodos. El motor de almacenamiento es
log-structured. Las escrituras nuevas van primero a una tabla en memoria. A
intervalos, el motor escribe esta tabla al disco como archivos ordenados que no
cambian.

Las lecturas vienen de esos mismos archivos. Así los escritores no cambian los
datos que los lectores usan, y las lecturas y las escrituras casi no tienen
efecto entre sí. La eliminación de registros es parte de la disposición del
almacenamiento. Cada fila tiene un TTL. La compactación por ventanas de tiempo
pone las filas de una ventana de tiempo en los mismos archivos. Así el motor
puede descartar los datos viejos como archivos completos, y no fila por fila.

Este diseño es correcto. Este artículo no dice que el diseño está mal. Pero
durante el despliegue, encontré el problema. Pregunté: "¿Cuál es el número real
de mensajes por segundo de su CGNAT?" La respuesta fue: "25.000 mensajes por
segundo, con ráfagas de hasta 34.000 mensajes por segundo".

El diseño usó cinco contenedores diferentes para una carga que era una parte
pequeña de su capacidad posible. Esto fue un desperdicio de recursos, y la
solución era demasiado grande. Cada parte del sistema es simple cuando la parte
está sola. Pero la integración, el trabajo de depuración y el mantenimiento de
todas las partes juntas son muy complejos.

## La deuda técnica

La mayoría del software que usamos es software de un solo núcleo y un solo
hilo. Por esto, pensamos que el software que no escala horizontalmente es
deuda. Esto no es correcto. Un mejor diseño nos deja usar la capacidad completa
de nuestras máquinas. La causa verdadera de la deuda técnica es diferente. La
deuda técnica ocurre cuando hacemos software, pero no entendemos su proceso y
sus condiciones específicas.

Cuando hice la primera solución, no entendí qué tenía que hacer el software.
Hice una solución general que no era correcta para el cliente. Una decisión es
correcta solo para su momento y sus condiciones. Una buena decisión de diseño
está de acuerdo con el conocimiento actual del problema. Si el problema o el
comportamiento del sistema cambia en el futuro, entonces debemos refactorizar
el código.

Una sesión de suscriptor envía un mensaje en su creación, un mensaje a
intervalos de algunos minutos, y un mensaje en su liberación. Así cada usuario
produce menos de un mensaje por segundo. Medimos 25.000 mensajes por segundo,
con ráfagas de 34.000 mensajes en la hora pico. Para hacer este número dos
veces más grande, millones de suscriptores nuevos deben llegar al cliente en
una noche.

La infraestructura desplegada tenía una capacidad de más de 1.000.000 de
mensajes por segundo. Esto es aproximadamente 30 veces la carga de la hora
pico. El crecimiento del número de usuarios no era el objetivo correcto del
diseño. Millones de suscriptores nuevos no llegan a un carrier sin aviso.

## Simplicidad

Empecé otra vez. Esta vez empecé desde la carga de trabajo, no desde la
arquitectura. Pregunté: ¿qué es necesario para la carga de trabajo ahora?

- **La retención es de minutos.** "Durabilidad" significa que los datos están
  disponibles por una ventana de almacenamiento.
- **La fuente es syslog por UDP.** El transporte pierde mensajes antes de que
  los mensajes lleguen al software. Por eso el mejor pipeline es un pipeline
  que no agrega pérdida propia.
- **La primera unidad de despliegue es una máquina.** Todas las partes del
  pipeline van juntas en un despliegue. Así "distribuido" no cruza el límite de
  una máquina, pero sí cruza un límite de software. Si el rendimiento no es
  suficiente, podemos dividir la solución otra vez, parte por parte.

## Un shard por cada núcleo

Entonces hice una solución más simple. La solución mantiene la idea de
particiones para las escrituras. Pero cada partición es ahora una goroutine, no
una partición de broker. El número de shards viene de `runtime.GOMAXPROCS(0)`,
que da el número de procesadores del contenedor. Más shards no aumentan el
rendimiento, porque el camino de escritura está limitado por la CPU.

```
    syslog (UDP)
         │
         ▼
    listener ──► parse queue ──► parse workers ──► store queue ──► store
                   (chan)                            (chan)       workers
                                                                 (1 per core)
                                                          ┌───────────┘
                                                          ▼
                            in-memory map  +  in-memory SQLite window
                                  │                        │ seal
                                  ▼                        ▼
        query API  ◄──────── live map first, then sealed, indexed,
                             read-only files · dropped after TTL
```

Cada núcleo tiene un store worker, una ventana de SQLite en memoria y su propio
conjunto de mapas de llaves en vivo. El nombre de cada archivo sellado contiene
el ID del shard y un timestamp. Una lectura examina los archivos del más nuevo
al más viejo, y para cuando encuentra el registro. Así ninguna coordinación
entre los shards es necesaria. Para aumentar el throughput, cambias una línea
en la especificación del despliegue: el límite de CPU.

## Ventanas de SQLite y el procedimiento de sellado

El camino de escritura es una base de datos SQLite en memoria, con **cero
índices**, y con los pragmas de durabilidad apagados. Esto no es un riesgo,
porque la base de datos está en RAM. La copia durable es la copia en el disco.
Un insert es un append en una transacción por lotes, y el motor no ajusta un
índice B-tree por cada fila. Así este camino de escritura tiene el costo más
bajo posible.

La ventana se "sella" a intervalos de algunos segundos, o cuando la ventana
llega a su límite de filas:

1. El worker escribe la ventana a un archivo temporal en el disco con
   `VACUUM INTO`.
2. El worker construye los tres índices de consulta sobre esa copia, una vez,
   para todas las filas.
3. El worker renombra el archivo a su nombre final en una operación atómica.

La operación de renombrado es el protocolo de sellado. Los lectores encuentran
solo los archivos completos. Así los lectores no pueden ver un sellado escrito
parcialmente. El timestamp en cada nombre de archivo muestra la edad de los
datos. Así "el más nuevo primero" es solo un ordenamiento de los nombres de
archivo.

La operación de sellado ocurre en su propia goroutine. Al mismo tiempo, el
worker abre una ventana nueva y continúa la ingestión. Así el I/O de disco no
detiene la ingestión.

El procedimiento de TTL usa el mismo principio que la compactación por ventanas
de tiempo del almacén de columnas anchas, pero solo con archivos. El limpiador
quita los datos viejos cuando borra archivos completos. El limpiador nunca
borra datos fila por fila. El limpiador mantiene un margen de seguridad después
del TTL nominal. El limpiador también mantiene un número mínimo de archivos,
que viene del TTL, del largo de la ventana y del número de shards. Así, si hay
un error, el limpiador conserva demasiados datos, no muy pocos.

Los archivos sellados son solo archivos. Así, después de un reinicio, el
sistema carga todos los archivos que no están expirados. Un arranque en
caliente usa cero código de recuperación, porque los archivos en el disco _son_
la metadata. Después de un reinicio, la pérdida es solo la ventana de
almacenamiento actual, más el tiempo que el contenedor usa para arrancar.

## Datos en tiempo real

Un registro nuevo no va al disco inmediatamente. El registro puede estar en la
ventana abierta por un máximo del largo de una ventana. Por eso cada shard
también mantiene mapas en vivo en memoria para su ventana abierta. Hay un mapa
por cada eje de consulta, y todos los mapas apuntan al mismo registro. La
operación de sobreescritura de un mapa conserva el mapeo más reciente. Ninguna
estructura de orden es necesaria.

El cambio de una ventana a la siguiente debe ser exacto. El sistema agrega los
mapas de la ventana nueva _antes_ de que la ventana nueva reciba tráfico. El
sistema quita los mapas viejos solo _después_ de que el sellado de la ventana
vieja está completo en el disco. Así cada registro está disponible en un lugar
o más, en todo momento. Si los sellados se vuelven lentos y el directorio de
mapas se llena, la ventana cambia a modo solo-disco y da una advertencia. La
ingestión no se detiene, porque la disponibilidad del camino de escritura es
más importante que los datos más recientes de consulta.

## El buffer del socket UDP

Durante un sellado, un pod con un núcleo detiene la ingestión por un tiempo
corto. Kafka no está en este diseño. Por eso el único buffer entre esa parada y
la red es el buffer de recepción UDP del kernel. El tamaño por defecto de este
buffer en el sistema operativo es de aproximadamente 208 KB. Cuando este buffer
está lleno, el kernel descarta el desborde antes de que los datos lleguen a
nuestro software, y no da ninguna indicación. Así nuestros contadores mostraban
cero pérdidas mientras el kernel descartaba paquetes.

La corrección fue simple. Pusimos un buffer de recepción suficientemente grande
para los datagramas de un sellado completo, con la opción `SO_RCVBUFFORCE`.

## El margen vertical

Con el diseño actual, cada núcleo agregado (3,6 GHz) agrega capacidad para
aproximadamente 45.000 mensajes por segundo. Cada núcleo agregado usa
aproximadamente 1,4 GB de RAM y 2,5 GB de almacenamiento. Las consultas en vivo
continúan con respuestas en aproximadamente 20 ms.

Para calcular el tamaño de la máquina, empecé desde el punto de falla: ¿qué
debe ocurrir para que este diseño quede pequeño? Un pod con 4 núcleos puede
recibir y almacenar aproximadamente 180.000 mensajes por segundo. Esto es más
de cinco veces la carga de la hora pico. Cada usuario agrega menos de un
mensaje por segundo. Así un aumento de ese tamaño es posible solo si millones
de suscriptores nuevos llegan sin aviso.

## Nota final

El punto más importante es este: empieza pequeño, y mantén el sistema en una
unidad. Primero, entiende un sistema que es suficientemente simple para ser
claramente correcto. Encuentra los procesos que deben ser secuenciales y los
procesos que pueden ser concurrentes. Diseña el sistema, mide el sistema, y
dale al sistema un margen de capacidad. Mantén la infraestructura infinita como
un posible paso posterior. Peor es mejor, hasta que deja de serlo.

¿Quieres hablar de estos temas? ¿Piensas que estoy equivocado? ¿Tienes algo
nuevo para mostrarme? Por favor contáctame. Yo responderé.

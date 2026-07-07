---
title: '"Peor es Mejor", construyendo un ingestor de logs CGNAT en Go'
date: 2026-07-03T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["go", "SQLite", "Kafka", "Arquitectura", "CGNAT"]
categories: ["programación"]
---

Hay un ensayo viejo de Richard Gabriel, _The Rise of Worse is Better_, que
argumenta que el sistema que es simple de implementar y cubre la mayoría de los
casos le gana en la práctica al sistema completo, correcto y complejo. La
cultura startup terminó demostrando el punto sin proponérselo: llegar rápido al
mercado con una buena idea a medio ejecutar, y volverla un producto real con el
tiempo, vale más que llegar tarde con la perfecta.

Al mismo tiempo, de manera contraintuitiva y contradictoria, con los unicornios
y las empresas basadas en crecimiento llegó la idea opuesta: que todo sistema
tiene que ser infinitamente escalable, diseñado desde el primer día para un
sinfín de funcionalidades y para el crecimiento horizontal. Lo que eso deja
atrás, en lo que a mí respecta, es software mal hecho distribuido sobre cada
producto que un proveedor de nube esté dispuesto a venderte.

Este artículo presenta un ingestor de logs de CGNAT que, bajo las ideas actuales
del software, se clasificaría como "peor". Con él quiero cuestionar esa noción
que nos siguen vendiendo, que resolver el problema de hoy en vez del de mañana
es deuda técnica, mientras muestro cómo lidiar con las complicaciones que trae
mantener todo simple.

## El problema

Carrier-Grade NAT (CGNAT) es la forma en que un ISP pone miles de suscriptores
detrás de un grupo pequeño de direcciones IPv4 públicas. Cada dispositivo CGNAT
emite una línea de log por cada sesión que maneja, desde la creación, pasando
por sustains periódicos, hasta la liberación, y la gente que opera esa red
necesita responder una pregunta rápido: _¿qué suscriptor estaba detrás de esta
IP pública y este PORT hace un momento?_ La misma información se necesita desde
tres direcciones distintas: por dirección pública y puerto, por dirección
privada y puerto, y por suscriptor.

Tres propiedades de esta carga de trabajo dirigen cada decisión que viene
después:

- **Tasa de escritura extremadamente alta**: decenas de miles de líneas de log
  por segundo llegan por syslog, continuamente.
- **Retención extremadamente corta**: un mapeo solo importa por minutos. La idea
  es tener una captura en tiempo real de lo que está pasando en la red.
- **Lecturas de lo más reciente**: cada búsqueda requiere el último mapeo para
  una llave.

## El enfoque inicial

La idea inicial era un sistema distribuido capaz de redirigir un proceso
secuencial de generación de logs hacia un procesador distribuido de esos logs.

Para llegar ahí, seguí un solo registro del CGNAT a través de la cadena de
transformaciones que le tocaría vivir:

```
 Carrier SysLog -> receiver -> parsing -> storage <- query api <- user
```

Para un registro, levanté las diferentes partes del proceso. La idea principal
es revisar cómo se comporta cada parte del proceso de manera secuencial,
tratando de distanciarme primero de los modelos de concurrencia, ya que la
ejecución no determinista puede complicar todo mi entendimiento.

Cuando termino con eso, trato de analizar el sistema con dos registros y así
encontrar las partes comunes entre los procesos. Cuando veo dos registros al
mismo tiempo, puedo encontrar dos puntos de cruce: el receptor, porque todos los
mensajes llegan secuencialmente a máxima velocidad, y el almacenamiento, porque
ahí es donde todos los mensajes de la ventana actual de Time To Live van a
co-existir.

Eso me dijo cuáles eran las dos estructuras de datos que tenía que elegir bien.
Después de la recepción necesitaba algo que le permitiera al receptor entregar
un mensaje y volver al socket inmediatamente, porque un datagrama para el que el
receptor no está listo es un datagrama perdido: una cola acotada, que absorbe
las ráfagas y desacopla la velocidad a la que llegan los mensajes de la
velocidad a la que se parsean. Y para el almacenamiento necesitaba algo que
pudiera tragarse decenas de miles de escrituras por segundo.

Como la cantidad de registros supera la cantidad de escrituras que una base de
datos puede manejar, tuve que pensar en otra estructura, como una colección
iterable, para agrupar por lotes todos los registros que llegan.

Esas dos cosas dividen el software en dos partes principales: el ingestor, que
necesita ser liviano y ágil, y el escritor, que necesita parsear y preparar los
datos para la escritura en la base de datos.

## Complejidad vendida como sencillez

Como pregunta para todo sistema mientras se diseña, se presentó _¿cómo escala la
solución?_. Parecía bastante simple: como el receptor necesita recibir los
mensajes del UDP secuencialmente, se convirtió en el principal cuello de botella
de rendimiento, y como yo iba a almacenar todo en colas, el trabajo serializado
se vuelve horizontalmente escalable, ya que distintos escritores pueden tomar de
distintas partes de la cola a medida que se llena. Y el sistema empieza a verse
así:

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

Cada pieza está ahí por una razón. Kafka es el buffer elástico que absorbe
ráfagas cuando el almacén se atrasa, y te da replay cuando un escritor se cae.
Las particiones son la palanca de escalamiento horizontal: agrega particiones y
escritores, y el pipeline sigue. El consumer group te da recuperación ante
caídas sin escribir ningún código de coordinación. Escalado, este diseño sigue
el chorro completo de un carrier grande: **más de un millón de mensajes por
segundo**.

Para el almacenamiento elegí Cassandra, porque está construida exactamente para
esta forma de carga de trabajo. Una base de datos distribuida de columnas anchas
particiona los datos por llave a través del clúster, así que la capacidad de
escritura escala horizontalmente agregando nodos. Su motor de almacenamiento es
log-structured: las escrituras entrantes caen en una tabla en memoria que
periódicamente se vuelca a archivos inmutables y ordenados en disco, y las
lecturas se sirven desde esos mismos archivos inmutables, así que los escritores
nunca reescriben lo que los lectores están usando y las lecturas y escrituras
concurrentes apenas se tocan. La eliminación de registros está en la disposición
del almacenamiento: las filas llevan un TTL, y con la compactación por ventanas
de tiempo las filas de una ventana terminan en los mismos archivos, así que los
datos expirados se botan como archivos enteros en vez de fila por fila.

Este diseño es correcto. El punto de este artículo no es que esté mal. Pero no
fue sino hasta que empezamos su despliegue que empezó a caerme la ficha. _"¿Me
puedes decir cuáles son los números reales de mensajes por segundo que está
produciendo su CGNAT?"_, pregunté. _"**25k** mensajes que pueden llegar en
ráfagas de hasta 34k mensajes por segundo"_, me dijeron.

5 contenedores distintos, para un número que era una fracción de lo que el
diseño posiblemente es capaz de manejar, no solo era un desperdicio de recursos,
se sintió como si hubiera sobredimensionado la solución. Las partes del sistema
son simples por sí solas, pero extremadamente complejas de integrar, depurar y
mantener.

## Qué es realmente la deuda técnica

Por la noción de que la mayoría del software que corremos es de un solo núcleo y
un solo hilo, tendemos a asociar la falta de escalabilidad horizontal con deuda,
pero esa no es para nada la realidad; solo tenemos que crear un diseño más
robusto para poder usar todas las capacidades de las máquinas con las que
trabajamos. El punto principal de la deuda técnica es la creación de software
cuyo proceso y requerimientos específicos no entendemos.

Al crear la primera solución, siento que realmente no entendí los requerimientos
del software, ya que creé una solución general que no encajaba del todo con las
necesidades del cliente. Las decisiones tienen un momento y un lugar. Las
decisiones de diseño actuales, si se toman bien, responden al entendimiento
actual del problema, y si en el futuro los requerimientos, los problemas o las
características de comportamiento cambian, no deberíamos tener miedo de
refactorizar nuestro código.

Una sesión de suscriptor produce un mensaje cuando se crea, uno cada pocos
minutos mientras sigue viva, y uno cuando se libera, dándonos una fracción de
mensaje por segundo por usuario. Dale la vuelta a la relación, y para que los
25k mensajes por segundo que medimos, con ráfagas de 34k en hora pico, apenas se
dupliquen, el cliente tendría que ganar millones de suscriptores de la noche a
la mañana. Contra eso, la infraestructura que desplegamos estaba dimensionada
para más de un millón de mensajes por segundo, unas treinta veces la hora pico.
El crecimiento de usuarios nunca fue lo que había que diseñar aquí; ningún
carrier gana millones de suscriptores sin anunciarlo.

## Simplicidad

Empezando de nuevo, esta vez desde los requerimientos y no desde la
arquitectura, pregunté qué es lo que la carga de trabajo realmente exige ahora:

- **La retención es de minutos.** "Durabilidad" significa sobrevivir una ventana
  de almacenamiento.
- **La fuente es syslog por UDP.** El transporte es lossy antes de que el
  mensaje llegue al software, así que lo mejor que puede hacer cualquier
  pipeline es no agregar pérdida propia.
- **Estamos apuntando primero a una sola máquina como unidad de despliegue.** El
  pipeline entero se entrega junto, así que "distribuido" nunca cruza realmente
  el límite de una máquina, pero sí cruza uno de software. Si el rendimiento no
  está, podemos empezar a separar la solución de nuevo, pero por partes.

## Núcleos como shards, la única perilla de escalamiento

Se creó una solución más simple. Mantiene la idea del uso de particiones en la
escritura, donde lo que yo quería descargar era el proceso de almacenamiento,
pero la partición se vuelve una goroutine en vez de una partición de broker. La
cantidad de shards se deriva de `runtime.GOMAXPROCS(0)`, lo cual representa la
cantidad de procesadores que tiene el contenedor, ya que más shards no compran
nada en un camino atado a CPU, que en este caso es el camino de escritura.

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

Cada núcleo es dueño de un store worker, de su propia ventana de SQLite en
memoria, y de sus propios mapas de llaves en vivo. Los archivos sellados llevan
el ID del shard y un timestamp en el nombre, y las lecturas recorren los
archivos del más nuevo al más viejo hasta el primer acierto, así que no hay
coordinación entre shards en ninguna parte. El throughput escala editando una
línea en la especificación del despliegue: el límite de CPU.

## SQLite por ventanas, y el sistema de almacenamiento como protocolo de sellado

El camino de escritura es una base de datos SQLite en memoria con **cero
índices** y los pragmas de durabilidad apagados. Suena imprudente hasta que
recuerdas que es RAM: la copia durable es la que está en disco. Un insert es un
append sin índices dentro de una transacción por lotes, el camino caliente más
barato posible, porque ningún B-tree tiene que mantenerse por fila.

Cada pocos segundos, o cuando la ventana llega a su tope de filas, la ventana se
**sella**:

1. `VACUUM INTO` hacia un archivo temporal en disco.
2. Construir los tres índices de búsqueda sobre esa copia sellada, una vez, en
   bloque.
3. Renombrarla atómicamente a su lugar.

El renombrado es el protocolo de sellado. Los lectores solo listan archivos
completos, así que un sellado a medio escribir es invisible para ellos. La
recencia está codificada en los nombres con marca de tiempo, así que "el más
nuevo primero" es ordenar nombres de archivo. El sellado corre en su propia
goroutine mientras el worker abre una ventana fresca y sigue ingiriendo, así que
el I/O de disco nunca bloquea la entrada.

Hacer cumplir el TTL es el mismo truco que el almacén de columnas anchas hacía
con la compactación por ventanas de tiempo, implementado con nada más que
archivos: los datos expirados se botan des-enlazando archivos enteros, nunca con
eliminaciones por fila. El limpiador mantiene un margen de seguridad cómodamente
después del TTL nominal, y una cantidad mínima de archivos derivada del TTL, del
largo de la ventana y de la cantidad de shards, así que siempre se equivoca
hacia conservar datos. Y como los archivos sellados son solo archivos, un
reinicio recarga lo que no haya expirado: el arranque en caliente necesita cero
código de recuperación, porque los archivos en disco _son_ la metadata. Cuando el
sistema se reinicia, solo se pierde la ventana de almacenamiento actual, más el
tiempo que el contenedor necesita para reiniciarse.

Si este plan te suena familiar, es porque es el plan que el almacén de columnas
anchas corre internamente: una tabla de escritura en memoria, volcada a archivos
inmutables y ordenados que los lectores usan, con la expiración manejada botando
archivos enteros. No inventé un motor de almacenamiento, tomé el plan del grande
y le quité el clúster de alrededor.

## Datos en tiempo real

Un registro no se sella a disco hasta por una ventana entera, así que cada shard
también mantiene mapas en memoria sobre su ventana abierta, un mapa por eje de
búsqueda, todos apuntando al mismo registro. "El mapeo más reciente" sale solo
de la semántica de sobreescritura de los mapas, sin ninguna estructura de
ordenamiento. El relevo es la parte que tiene que ser exacta: los mapas de la
ventana nueva se registran _antes_ de que reciban tráfico, y los viejos se
quitan solo _después_ de que su sellado termine de escribir a disco, así que
cada registro se puede encontrar en al menos un lugar en todo instante. Y si los
sellados se atrasan y el registro de mapas se llena, la ventana se degrada a
solo-disco con una advertencia en vez de bloquear la ingestión, porque la
disponibilidad del camino de escritura está por encima de la frescura de las
consultas.

## Los puertos también tienen buffers

Durante un sellado, un pod de un núcleo pausa la ingestión por un instante. Sin
Kafka, el único buffer entre esa pausa y el cable es el buffer de recepción del
socket UDP del kernel, y con el tamaño por defecto del sistema operativo (unos
208 KB) el desborde se pierde en silencio, antes de llegar a nuestro software.
Por esto, aunque estábamos perdiendo mensajes, cada contador que era nuestro
marcaba cero pérdidas mientras los paquetes desaparecían. El arreglo fue simple:
forzar un buffer de recepción lo suficientemente grande para aguantar los
datagramas de un sellado completo, usando `SO_RCVBUFFORCE`.

## Espacio para crecer vertical

Con el diseño actual, cada núcleo agregado (3.6 GHz) compra aproximadamente 45k
mensajes por segundo y cuesta cerca de 1.4 gigas de RAM y 2.5 gigas de
almacenamiento, mientras las consultas en vivo siguen respondiendo en unos 20
ms.

Para dimensionar la máquina trabajé hacia atrás desde la falla: ¿qué tendría que
pasar para que este diseño quede pequeño? Un pod de 4 núcleos maneja alrededor
de 180k mensajes por segundo, más de cinco veces la hora pico, y como cada
usuario agrega solo una fracción de mensaje por segundo, un salto así requeriría
millones de suscriptores nuevos llegando sin anunciarse.

## Nota final

Al final, la lección principal es que siempre deberíamos empezar pequeño y
auto-contenido. Envuelve tu cabeza alrededor de un sistema que sea lo
suficientemente simple para ser obviamente correcto, separa qué procesos
necesitan ser secuenciales y qué procesos pueden ser concurrentes, diséñalo,
mídelo, créale espacio para crecer, y trata de mantener el enfoque de
infraestructura infinita en el bolsillo de atrás. Peor es mejor, hasta que deja
de serlo.

Si quieres discutir cosas de esta naturaleza, decirme que me equivoqué, o
mostrarme algo interesante, no tengas miedo de contactarme, con gusto responderé
a tu llamado.

---
title: '"Peor es Mejor", construyendo un ingestor de logs CGNAT'
date: 2026-07-03T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["go", "SQLite", "Kafka", "Arquitectura", "CGNAT"]
categories: ["programación"]
---

Hay un ensayo viejo de Richard Gabriel, _The Rise of Worse is Better_, que
argumenta que el sistema que es simple de implementar y cubre la mayoría de los
casos le gana en la práctica al sistema completo, correcto y complejo. Y aunque
ahora con la idea de los emprendimientos, donde es más valioso llegar al mercado
rápidamente, con una buena idea medio ejecutada y volverla un producto
eventualmente, demuestran lo importante que puede ser esa idea.

A la misma vez de manera contra intuitiva y contradictoria, también, con la
llegada de los unicornios y empresas basadas en crecimiento, llega también la
idea de que todo sistema tiene que ser infinitamente escalable, donde todo tiene
que ser diseñable en pro del desarrollo de un sin fin de funcionaliades y de
manera tal que el crecimiento horizontal sea compatible desde el principio.
Donde queda en lo que a mi respecta, software mal hecho distrubuído en todos los
posibles productos que tienen los vendedores de nube.

En este artículo se plantea una solución referente a un ingestor de logs de un
CGNAT que bajo todas las ideas actuales de software se podría clasificar como
"peor", pero realmente se centra totalmente en las necesidades actuales del
cliente y simplicidad.

## EL PROBLEMA

Carrier-Grade NAT (CGNAT) es la forma en que un ISP pone miles de suscriptores
detrás de un grupo pequeño de direcciones IPv4 públicas. Cada dispositivo CGNAT
emite una línea de log por cada sesión que mapea, y la gente que opera esa red
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

Mira esas tres juntas y el replanteamiento se sugiere solo: esto no es una base
de datos, es un **caché de búsqueda que se cura solo**. Se regenera cada pocos
segundos desde el chorro de logs, y si lo pierdes, se vuelve a calentar por su
cuenta. Guarda esa idea, porque nos tomó un sistema distribuido entero poder
verla.

## PLANTEAMIENTO INICIAL

Como idea inicial, se plantea un sistema distribuído de que capaz de
redireccionar un sistema de generación secuencial de logs a un procesador
distribuído de estos.

Para lograrlo, se diseñó un sistema de transformaciones secuenciales iniciales
para seguir la transformación de un sólo registro del CGNAT y desde allí se
comenzó a evaluar, que partes del proceso se tenían que hacer de manera
sequencial y que partes del proceso se podían hacer de manera asíncrona.

```
 Carrier SysLog -> receiver -> parsing -> storage <- query api <- user

```

Dado el caso que el envío de mensajes era a través de una conexión UDP, la
capacidad de recibir todos los mensajes enviados era fundamental para el
funcionamiento del proceso y desde ahí se comenzó a dividir el problema en
partes.

## COMPLEJIDAD VENDIDA COMO SENCILLEZ

Aunque ya teníamos una idea de las necesidades del cliente y del sistema, un
requerimiento adicional surge sin ningún tipo de interrogación, _el sistema
tiene que escalar_,

El primer sistema nació del requerimiento que todo el mundo declara y nadie
interroga: _tiene que escalar_. Y es el diseño que dibujarías en cualquier
entrevista de diseño de sistemas. Un receptor toma el flujo de syslog y produce
cada línea cruda hacia Kafka. Un consumer group de parsers escribe por lotes en
un almacén distribuido de columnas anchas, con una tabla desnormalizada por eje
de búsqueda, y compactación por ventanas de tiempo para que los datos expirados
se boten como archivos enteros en vez de fila por fila. La entrega es
at-least-once, confirmando offsets solo después de una escritura exitosa, con
upserts idempotentes para que las repeticiones sean inofensivas.

```
             CGNAT devices (syslog UDP/TCP)
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
        │ parser  │  │ parser  │  │ parser  │  parse · batch · write
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
ráfagas cuando el almacén se atrasa, y te da replay cuando un parser se cae. Las
particiones son la palanca de escalamiento horizontal: agrega brokers, agrega
consumidores, y el pipeline sigue. El consumer group te da recuperación ante
caídas sin escribir ningún código de coordinación. Escalado, este diseño sigue
el chorro completo de un carrier grande: **más de un millón de mensajes por
segundo**, sin que ninguna máquina sea especial.

Este diseño es correcto. El punto de este artículo no es que esté mal.

## QUÉ ES REALMENTE DEUDA TÉCNICA

## SIMPLICIDAD

No planeaba repetir ese experimento en el trabajo, pero pasó de todas formas:
diseñamos un ingestor de logs CGNAT para escalar horizontalmente hasta el
infinito, y terminamos entregando un solo proceso de Go en un solo contenedor.

Este artículo es la historia de ese camino de vuelta: por qué existió el diseño
grande, qué nos hizo re-evaluarlo, hasta dónde llega realmente el sistema
"peor", y por qué el grande sigue esperando al final del camino. Para seguir el
hilo deberías tener un conocimiento general de Go y estar familiarizado con cómo
se arman normalmente los pipelines de ingestión estilo Kafka.

## El problema es un caché disfrazado de base de datos

## Diseñando para el infinito

El primer sistema nació del requerimiento que todo el mundo declara y nadie
interroga: _tiene que escalar_. Y es el diseño que dibujarías en cualquier
entrevista de diseño de sistemas. Un receptor toma el flujo de syslog y produce
cada línea cruda hacia Kafka. Un consumer group de parsers escribe por lotes en
un almacén distribuido de columnas anchas, con una tabla desnormalizada por eje
de búsqueda, y compactación por ventanas de tiempo para que los datos expirados
se boten como archivos enteros en vez de fila por fila. La entrega es
at-least-once, confirmando offsets solo después de una escritura exitosa, con
upserts idempotentes para que las repeticiones sean inofensivas.

```
             CGNAT devices (syslog UDP/TCP)
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
        │ parser  │  │ parser  │  │ parser  │  parse · batch · write
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
ráfagas cuando el almacén se atrasa, y te da replay cuando un parser se cae. Las
particiones son la palanca de escalamiento horizontal: agrega brokers, agrega
consumidores, y el pipeline sigue. El consumer group te da recuperación ante
caídas sin escribir ningún código de coordinación. Escalado, este diseño sigue
el chorro completo de un carrier grande: **más de un millón de mensajes por
segundo**, sin que ninguna máquina sea especial.

Este diseño es correcto. El punto de este artículo no es que esté mal.

## Llega la factura

Después lo cotizamos, en plata y en cerebro.

El diseño infinito son cinco servicios antes de que fluya el primer byte:
receptor, broker, parsers, almacén, y algo que los vigile a todos. Los brokers
necesitan discos, réplicas y planeación de particiones. El almacén necesita
planeación de capacidad y ajuste de compactación. Cada salto es un contrato que
versionar, un dashboard que construir, un modo de falla que ensayar. Nada de
esto se desperdicia a un millón de mensajes por segundo, es exactamente lo que
cuesta esa escala.

Pero las primeras redes reales que teníamos que atender emitían decenas de miles
de mensajes por segundo, no un millón. Estábamos a punto de operar un acelerador
de partículas para partir una nuez. Así que auditamos lo que la carga de trabajo
realmente exige:

- **La retención es de minutos.** Un log durable es una máquina para no perder
  datos, pero aquí los datos expiran antes de que la durabilidad se pague sola.
  "Durabilidad" significa sobrevivir una ventana de almacenamiento, no
  sobrevivir un datacenter.
- **La fuente es syslog por UDP.** El transporte es lossy antes de que toquemos
  el mensaje, así que exactly-once nunca estuvo sobre la mesa. Lo mejor que
  puede hacer cualquier pipeline es no agregar pérdida propia.
- **La unidad de despliegue es una sola máquina de todas formas.** Para estos
  despliegues el pipeline entero corre junto, así que "distribuido" nunca cruzó
  realmente el límite de una máquina. Estábamos pagando costos de coordinación
  entre procesos que no necesitaban ser procesos separados.

Lo que sobrevivió la auditoría fue el **contrato**: tres ejes de búsqueda, TTL
corto, reglas de parseo por fuente, gana lo más reciente. Lo que no sobrevivió
fue la **topología**. Así que construimos el sistema peor: el pipeline completo,
recibir, parsear, almacenar, consultar, como **un solo proceso de Go en un solo
contenedor**, con dos canales acotados donde antes estaba Kafka y SQLite por
ventanas donde antes estaba el almacén distribuido.

## Núcleos como shards, la única perilla de escalamiento

La edición pequeña conserva la idea de sharding de las particiones de Kafka,
pero el shard se vuelve una goroutine en vez de una partición de broker. La
cantidad de shards se deriva de `runtime.GOMAXPROCS(0)`, que en Go moderno es
consciente de los cgroups, así que sigue el límite de CPU del contenedor.
Deliberadamente no es una perilla de configuración: más shards que núcleos no
compra nada en un camino atado a CPU, así que no hay nada que un operador pueda
configurar mal.

```
    syslog (UDP/TCP)
         │
         ▼
    listener ──► parse queue ──► parse workers ──► store queue ──► store
                   (chan)                            (chan)       workers
                                                                 (1 per core)
                                                                      │
                                        in-memory SQLite window  ◄────┘
                                                 │ seal
                                                 ▼
        query API  ◄────  sealed, indexed, read-only files · dropped
                          after TTL
```

Cada núcleo es dueño de un parse worker, un store worker, su propia ventana de
SQLite en memoria, y sus propios mapas de llaves en vivo. Los archivos sellados
llevan el ID del shard y un timestamp en el nombre, y las lecturas recorren los
archivos del más nuevo al más viejo hasta el primer acierto, así que no hay
coordinación entre shards en ninguna parte. El throughput escala editando una
línea en la especificación del despliegue: el límite de CPU. El rebalanceo se
reemplaza por no haber nada que rebalancear.

## SQLite por ventanas, y el filesystem como protocolo de commit

El camino de escritura es una base de datos SQLite en memoria con **cero
índices** y los pragmas de durabilidad apagados. Suena imprudente hasta que
recuerdas que es RAM: la copia durable es la que está en disco, así que
`synchronous = OFF` no cuesta nada. Un insert es un append sin índices dentro de
una transacción por lotes, el camino caliente más barato posible, porque ningún
B-tree tiene que mantenerse por fila.

Cada pocos segundos, o cuando la ventana llega a su tope de filas, la ventana se
**sella**:

1. `VACUUM INTO` hacia un archivo temporal en disco.
2. Construir los tres índices de búsqueda sobre esa copia sellada, una vez, en
   bloque.
3. Renombrarla atómicamente a su lugar.

El rename es el protocolo de commit. Los lectores solo listan archivos
completos, así que un sellado a medio escribir es invisible para ellos. La
recencia está codificada en los nombres con timestamp, así que "el más nuevo
primero" es ordenar nombres de archivo, sin manifiesto y sin catálogo. El
sellado corre en su propia goroutine mientras el worker abre una ventana fresca
y sigue ingiriendo, así que el I/O de disco nunca bloquea la entrada.

Hacer cumplir el TTL es el mismo truco que el almacén de columnas anchas hacía
con la compactación por ventanas de tiempo, implementado con nada más que
archivos: los datos expirados se botan des-enlazando archivos enteros, nunca con
deletes por fila. El limpiador mantiene un margen de seguridad cómodamente
después del TTL nominal, y una cantidad mínima de archivos derivada del TTL, el
largo de la ventana y la cantidad de shards, así que siempre se equivoca hacia
conservar datos. Y como los archivos sellados son solo archivos, un reinicio
recarga lo que no haya expirado: el arranque en caliente necesita cero código de
recuperación, porque la disposición en disco _es_ la metadata.

## La brecha de frescura, y backpressure sin broker

Dos garantías de la versión distribuida tuvieron que ganarse de nuevo, a
conciencia.

La primera es la frescura. Un registro no se sella a disco hasta por una ventana
entera, así que cada shard también mantiene mapas en memoria sobre su ventana
abierta, un mapa por eje de búsqueda, todos apuntando al mismo registro. "El
mapeo más reciente" sale solo de la semántica de sobreescritura de los mapas,
sin ninguna estructura de ordenamiento. El relevo es la parte que tiene que ser
exacta: los mapas de la ventana nueva se registran _antes_ de que reciban
tráfico, y los viejos se quitan solo _después_ de que su sellado termine de
escribir a disco, así que cada registro se puede encontrar en al menos un lugar
en todo instante. Y si los sellados se atrasan y el registro de mapas se llena,
la ventana se degrada a solo-disco con una advertencia en vez de bloquear la
ingestión: la disponibilidad del camino de escritura está por encima de la
frescura de las consultas, y eso es una decisión, no un accidente.

La segunda es el backpressure, y resulta que los transportes ya lo definen. El
camino UDP hace un envío no bloqueante al canal: soltar y contar.

```go
select {
case parseQueue <- msg:
default:
    metrics.DroppedUDP.Add(1) // UDP is lossy by contract: shed and count
}
```

El camino TCP hace un envío bloqueante normal, así que el control de flujo del
propio socket se vuelve la cola y el emisor se frena. La semántica que Kafka te
daba, re-derivada de lo que cada transporte ya promete.

## La cola que olvidaste que tenías, el kernel

Esta es la parte donde quitar el broker te pasa la cuenta.

Durante un sellado, un pod de un núcleo pausa la ingestión por un instante. Sin
Kafka, el único buffer entre esa pausa y el cable es el buffer de recepción del
socket UDP del kernel, y con el tamaño por defecto del sistema operativo, el
desborde se pierde en silencio. La parte fea es dónde ocurre la pérdida: arriba
del ciclo de lectura de la aplicación. Cada contador que era nuestro marcaba
cero pérdidas mientras los paquetes desaparecían. Los medidores por segundo
también mentían, porque un proceso privado de CPU reporta sus propias tasas
tarde. Lo que lo expuso fue comparar deltas de totales monotónicos a través del
límite del pipeline, lo emitido por el emisor contra lo almacenado, los únicos
números que no pueden mentir.

El arreglo es un patrón, no un número. Fuerza un buffer de recepción lo
suficientemente grande para aguantar los datagramas de un sellado completo, no
para suavizar el jitter de la red, usando `SO_RCVBUFFORCE` con la capability que
requiere, y cae de vuelta al `SO_RCVBUF` normal cuando falta el privilegio.
Después explota una rareza del kernel como health check: Linux reporta el valor
duplicado cuando lees el tamaño del buffer de vuelta, así que si `getsockopt`
devuelve menos del doble de lo que pediste, el nodo te recortó, y el proceso
grita al arrancar en vez de perder paquetes en silencio por semanas. Cuando
existe un modo de falla silencioso, fabrícale un delator ruidoso en el arranque.

Dos lecciones que vale la pena guardar. Primera, esa memoria del buffer se carga
al cgroup del contenedor, así que sobredimensionarlo cambia pérdida de paquetes
por un OOM kill. Segunda, y más general: cuando mueves trabajo fuera del camino
caliente hacia lotes periódicos, la sombra de latencia del lote tiene que
presupuestarse en algún lugar corriente arriba. El broker la absorbía antes.
Ahora la absorbe el kernel, pero solo si se lo pides.

## Espacio para crecer vertical

¿Hasta dónde llega el sistema peor? En un banco de pruebas con el pod fijado por
límites de cgroup, **un núcleo ingiere, parsea y almacena de 45,000 a 50,000
mensajes por segundo con cero pérdidas**, respondiendo consultas en vivo en unos
20 ms. Los shards siguen el límite de CPU, así que un pod de cuatro núcleos
supera los **150,000+ mensajes por segundo**, y la palanca de escalamiento sigue
siendo esa línea en la especificación del despliegue. La RAM queda acotada por
la ventana viva y no por la historia retenida, y el disco guarda la retención,
así que ambos siguen la tasa de ingestión de forma predecible.

Para la mayoría de las redes que este sistema atiende, eso ya es más que el
chorro completo. El sistema "peor" no es un compromiso a esa escala, es
simplemente la cantidad correcta de máquina.

## Cuando lo vertical se acaba

El diseño infinito no murió, se movió al final de la fila. Ambas ediciones
responden el mismo contrato: tres ejes de búsqueda, TTL corto, parseo por
fuente, gana lo más reciente. Así que cuando el chorro de un despliegue crece
más allá de los núcleos de una máquina, el pipeline completo, Kafka, consumer
groups y el almacén distribuido, toma el relevo y carga **más de un millón de
mensajes por segundo**. Graduarse es un cambio de infraestructura, no una
reescritura del producto, precisamente porque el contrato era el invariante y la
topología nunca lo fue.

El balance honesto de empezar pequeño: una ventana que se estrella pierde como
máximo una ventana de datos que de todas formas iban a expirar en minutos; nadie
más puede conectarse al flujo; el techo de una sola máquina es real; y una pila
de archivos SQLite por ventanas es algo que le tienes que explicar a tu SRE. A
cambio despliegas un binario en un contenedor, controlas el backpressure de
punta a punta en semántica de canales, la recuperación tras un reinicio es
listar un directorio, y el rendimiento por núcleo es predecible porque ningún
estado se comparte entre shards.

Empieza con el sistema que es lo suficientemente simple para ser obviamente
correcto, mide el espacio para crecer, y guarda el infinito para el día en que
las mediciones lo exijan. Peor es mejor, hasta que no lo es, y tus métricas te
van a avisar cuándo.

Si quieres hablar del patrón, o crees que me equivoqué en algún trade-off, no
tengas miedo de contactarme, estaré encantado de ayudar en lo que pueda.

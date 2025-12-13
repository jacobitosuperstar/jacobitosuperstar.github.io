---
title: Paralelismo en Python para el procesamiento de nubes de puntos
date: 2023-09-29T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["python", "LAS", "LAZ", "PointCloud", "LiDAR"]
categories: ["programación"]
---

LAS y su contraparte comprimida LAZ son formatos de archivo populares para
almacenar información de nubes de puntos, típicamente generados por tecnología
LiDAR. LiDAR, o Light Detection and Ranging, es una tecnología de teledetección
utilizada para medir distancias y crear mapas 3D altamente precisos de objetos
y paisajes. La información de la nube de puntos almacenada consiste
principalmente en coordenadas X, Y y Z, intensidad, color, clasificación de
características, tiempo GPS y otros campos personalizados proporcionados por el
escáner. Los archivos LAS comprenden millones de puntos que describen con
precisión el entorno u objeto detectado, lo que hace que su análisis sea una
tarea desafiante.

Uno de los pasos fundamentales en el procesamiento y análisis de datos 3D es
calcular las normales. Las normales en la nube de puntos proporcionan
información sobre la orientación y dirección de una superficie en cada punto de
la nube de puntos. Esta información es esencial para la visualización,
reconocimiento de objetos y análisis de formas.

No profundizaremos en los detalles de cómo se calculan estas normales o qué
paquete usar para ello. En cambio, el enfoque de este artículo es demostrar
cómo realizar cálculos paralelos mientras se lee y escribe por fragmentos un
archivo LAS/LAZ, y cómo Python gestiona los desafíos de la concurrencia y el
paralelismo.

Para seguir adelante, debes tener un conocimiento general de Python y estar
familiarizado con `numpy` y `laspy`. Este artículo proporciona una visión
general de alto nivel del paralelismo en Python.

```toml
[packages]
numpy = "==1.26.0"
laspy = {extras = ["lazrs"], version = "==2.5.1"}

[requires]
python_version = "3.10"
```

Tanto `laspy` como `numpy` son paquetes que interactúan directamente con la
C_API de Python, haciéndolos extremadamente rápidos. No hay mucho margen de
mejora en términos de velocidad sin recurrir a la programación directa en C.
Por lo tanto, necesitamos explorar nuevas formas de trabajar con nuestro código
para habilitar el paralelismo o mejorar los pipelines de procesamiento para
utilizar el potencial completo de nuestra máquina.

Como puedes o no saber, la ejecución de Python está limitada por el Global
Interpreter Lock (GIL). El GIL es un mecanismo utilizado por el Intérprete
CPython para asegurar que solo un hilo a la vez ejecute bytecode de Python.
Esto simplifica la implementación y hace que el modelo de objetos de CPython
sea seguro contra el acceso concurrente. Aunque el GIL ofrece simplicidad y
beneficios para programas multihilo y rendimiento de un solo núcleo y un solo
proceso, plantea preguntas: ¿Por qué usar multithreading si múltiples hilos no
pueden ejecutarse simultáneamente? ¿Es posible ejecutar código en paralelo con
Python?

El multithreading es un medio para hacer que Python sea no bloqueante,
permitiéndonos crear código que inicia múltiples tareas concurrentemente, aunque
solo una tarea puede ejecutarse en un momento dado. Este tipo de concurrencia
es útil cuando se hacen llamadas a APIs externas o bases de datos donde pasas
la mayor parte del tiempo esperando. Sin embargo, para tareas intensivas en
CPU, este enfoque tiene limitaciones.

Para ejecutar código Python en paralelo, la biblioteca `multiprocessing` genera
procesos separados en diferentes núcleos usando llamadas a la API del sistema
operativo.

**spawn** es el método predeterminado en MacOS y Windows. Crea procesos hijos
que heredan los recursos necesarios para ejecutar el método `run()` del objeto.
Aunque más lento que otros métodos (como fork), proporciona ejecución
consistente.

**fork** es el método predeterminado en todos los sistemas POSIX excepto MacOS.
Crea procesos hijos con todo el contexto y recursos del proceso padre. Es más
rápido que **spawn**, pero puede encontrar problemas en entornos multiproceso y
multihilo.

Este enfoque nos permite tener un nuevo intérprete de Python para cada
procesador, eliminando el problema de que múltiples hilos compitan por la
disponibilidad del intérprete.

Dado que el procesamiento de nubes de puntos depende en gran medida del
rendimiento de la CPU, empleamos multiprocesamiento para ejecutar procesos en
paralelo para cada fragmento de la nube de puntos que se está leyendo.

Para leer archivos LAS/LAZ grandes, `laspy` proporciona el `chunk_iterator`
para leer la nube de puntos en fragmentos de datos que pueden enviarse a
diferentes procesos para su procesamiento. Posteriormente, los datos procesados
se ensamblan y se escriben de vuelta en otro archivo por fragmento. Para lograr
esto, requerimos dos gestores de contexto: uno para leer el archivo de entrada
y otro para escribir el archivo de salida.

Así es como lo harías típicamente:

```python
import laspy
import numpy as np

# reading the file
with laspy.open(input_file_name, mode="r") as f:

    # creating a file
    with laspy.open(output_file_name, mode="w", header=header) as o_f:

        # iteration over the chunk iterator
        for chunk in f.chunk_iterator(chunk_size):
            # Normals calculation over each chunk
            point_record = calculate_normals(chunk)
            # writting or appending the data into the point cloud
            o_f.append_points(point_record)
```

Para paralelizar este proceso, creamos un `ProcessPoolExecutor` que nos permite
enviar cada ejecución de la función (donde calculamos las normales) a un
proceso separado. A medida que los procesos se completan, recopilamos los
resultados y los escribimos en el nuevo archivo LAS/LAZ.

Dado que recopilamos los resultados de los futuros en nuestro proceso principal
y luego los escribimos en el archivo, evitamos problemas donde múltiples
procesos acceden al mismo archivo simultáneamente. Si tu implementación no
permite este enfoque, es posible que necesites usar un `lock` para garantizar
la integridad de los datos.

```python
import laspy
import numpy as np
import concurrent.futures

# reading the file
with laspy.open(input_file_name, mode="r") as f:

    # creating an output file
    with laspy.open(output_file_name, mode="w", header=f.header) as o_f:

        # this is where we are going to collect our future objects
        futures = []
        with concurrent.futures.ProcessPoolExecutor() as executor:

            # iteration over the chunk iterator
            for chunk in f.chunk_iterator(chunk_size):

                # disecting the chunk into the points that conform it
                points: np.ndarray = np.array(
                    (
                        (chunk.x + f.header.offsets[0])/f.header.scales[0],
                        (chunk.y + f.header.offsets[1])/f.header.scales[1],
                        (chunk.z + f.header.offsets[2])/f.header.scales[2],
                    )
                ).T

                # calculate the normals  in a multi processing pool
                future = executor.submit(
                    process_points,   # function where we calculate the normals
                    points=points,
                )
                futures.append(future)

        # awaiting all the future to complete in case we needed
        for future in concurrent.futures.as_completed(futures):
            # unpacking the result from the future
            result = future.result()

            # creating a point record to store the results
            point_record = laspy.PackedPointRecord.empty(
                point_format=f.header.point_format
            )
            # appending information to that point record
            point_record.array = np.append(
                point_record.array,
                result
            )
            # appending the point record into the point cloud
            o_f.append_points(point_record)
```

Hay muchas cosas que desempacar de este código, como *¿por qué no estamos
usando el objeto chunk en sí mismo?*, *¿por qué estamos creando un
`PackedPointRecord` vacío?*.

Comenzaremos con el objeto `chunk`. Sin tocar el por qué, el objeto en sí
mismo no puede ser enviado para ser procesado en un pool de procesos. Debido a
eso, tenemos que extraer la información que encontramos importante de él. Como
estamos calculando las normales, lo que necesitamos son las coordenadas X, Y y
Z del Chunk, teniendo en cuenta el offset y la escala especificados en el
encabezado del archivo LAS/LAZ.

Dado que los cálculos nos devuelven un array de valores, que representarán las
coordenadas X, Y y Z, los valores RGB, la intensidad y la clasificación, no
podemos escribir eso directamente en el archivo LAS/LAZ, necesitamos crear un
`PackedPointRecord` con el formato especificado en el encabezado, en el cual
almacenaremos el array devuelto, y luego agregarlos al archivo LAS/LAZ.

El archivo LAS/LAZ tiene un objeto de encabezado, en el cual almacenamos la
escala, el offset y el formato de la nube de puntos. Esto es importante porque
para poder enviar información a ese archivo, el formato de nuestros valores
debe coincidir con el especificado en el encabezado. En nuestro caso, ambos
archivos tienen el mismo formato de encabezado. Sin embargo, si necesitas
escribir en archivos con diferentes versiones, el formato del array debe
coincidir con la versión a la que estás escribiendo.

Para identificar el formato requerido para poder agregar los resultados en el
`PackedPointRecord`, podrías ejecutar el siguiente comando,

```log
>>> f.header.point_format.dtype()
```

En este ejemplo, estamos usando el formato de punto versión 3, que tiene la
siguiente estructura:

```log
np.dtype([
    ('X', np.int32),
    ('Y', np.int32),
    ('Z', np.int32),
    ('intensity', np.int16),
    ('bit_fields', np.uint8),
    ('raw_classification', np.uint8),
    ('scan_angle_rank', np.uint8),
    ('user_data', np.uint8),
    ('point_source_id', np.int16),
    ('gps_time', np.float64),
    ('red', np.int16),
    ('green', np.int16),
    ('blue', np.int16),
])
```

Como no pudimos usar este comando, para hacer coincidir el dtype del futuro
desempacado con el dtype del encabezado.

```log
>>> result = result.astype(header.point_format.dtype())
```

tuvimos que hacer la transformación de la siguiente manera,

```python
def process_points(
    points: np.ndarray,
) -> np.ndarray:

    # normals calculation
    normals, curvature, density = calculate_normals(points=points)

    # RGB
    red, green, blue = 255 * (np.abs(normals)).T

    dtype = np.dtype([
        ('X', np.int32),
        ('Y', np.int32),
        ('Z', np.int32),
        ('intensity', np.int16),
        ('bit_fields', np.uint8),
        ('raw_classification', np.uint8),
        ('scan_angle_rank', np.uint8),
        ('user_data', np.uint8),
        ('point_source_id', np.int16),
        ('gps_time', np.float64),
        ('red', np.int16),
        ('green', np.int16),
        ('blue', np.int16),
    ])

    array = np.zeros(len(points), dtype=dtype)
    array['X'] = points[:, 0]
    array['Y'] = points[:, 1]
    array['Z'] = points[:, 2]
    array['intensity'] = density
    array['bit_fields'] = np.zeros(len(points), dtype=np.uint8)
    array['raw_classification'] = curvature
    array['scan_angle_rank'] = np.zeros(len(points), dtype=np.uint8)
    array['user_data'] = np.zeros(len(points), dtype=np.uint8)
    array['point_source_id'] = np.zeros(len(points), dtype=np.int16)
    array['gps_time'] = np.zeros(len(points), dtype=np.float64)
    array['red'] = red
    array['green'] = green
    array['blue'] = blue

    return np.ascontiguousarray(array)
```

Y con todo esto junto, somos capaces de procesar nubes de puntos grandes en
paralelo, utilizando todos los recursos de nuestra computadora.

Aunque se necesita un gran nivel de familiaridad con los paquetes mencionados
para entender y aplicar el código anterior, la idea era abordar uno de los
problemas comunes que hemos encontrado con el procesamiento de nuestras nubes
de puntos y compartir las soluciones que hemos encontrado para nuestros
problemas.

En caso de que haya algo más que necesite ser discutido, como un mejor enfoque
o si tienes dudas y quieres saber más sobre el código, no tengas miedo de
contactarme, estaré encantado de ayudar en lo que pueda.

---
title: Python Parallelism for Point Cloud Processing
date: 2023-09-29T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["python", "LAS", "LAZ", "PointCloud", "LiDAR"]
categories: ["programming"]
---

LAS and its compressed counterpart LAZ are popular file formats for storing
Point Cloud information, typically generated by LiDAR technology. LiDAR, or
Light Detection and Ranging, is a remote sensing technology used to measure
distances and create highly accurate 3D maps of objects and landscapes. The
Point Cloud information stored mainly consists of X, Y, and Z coordinates,
intensity, color, feature classification, GPS time, and other custom fields
provided by the scanner. LAS files comprise millions of points that accurately
describe the sensed environment or object, making their analysis a challenging
task.

One of the fundamental steps in processing and analyzing 3D data is calculating
the normals. Normals in the Point Cloud provide information about the
orientation and direction of a surface at each point in the point cloud. This
information is essential for visualization, object recognition, and shape
analysis.

We won't delve into the details of how these normals are calculated or which
package to use for it. Instead, the focus of this article is to demonstrate how
to perform parallel calculations while chunked reading and chunked writing of a
LAS/LAZ file, and how Python manages the challenges of concurrency and
parallelism.

To follow along, you should have a general knowledge of Python and be familiar
with `numpy` and `laspy`. This article provides a high-level overview of
parallelism in Python.

```toml
[packages]
numpy = "==1.26.0"
laspy = {extras = ["lazrs"], version = "==2.5.1"}

[requires]
python_version = "3.10"
```

Both `laspy` and `numpy` are packages that directly interact with the Python
C_API, making them extremely fast. There isn't much room for improvement in
terms of speed without resorting to direct C programming. Therefore, we need to
explore new ways to work with our code to enable parallelism or enhance
processing pipelines to utilize our machine's full potential.

As you may or may not know, Python execution is constrained by the Global
Interpreter Lock (GIL). The GIL is a mechanism used by the CPython Interpreter
to ensure that only one thread at a time executes Python bytecode. This
simplifies implementation and makes the object model of CPython safe against
concurrent access. While the GIL offers simplicity and benefits for
multithreaded programs and single-core, single-process performance, it raises
questions: Why use multithreading if multiple threads cannot execute
simultaneously? Is it possible to execute code in parallel with Python?

Multithreading is a means of making Python non-blocking, allowing us to create
code that initiates multiple tasks concurrently, even though only one task can
execute at any given moment. This type of concurrency is useful when making
calls to external APIs or databases where you spend most of the time waiting.
However, for CPU-intensive tasks, this approach has limitations.

To run Python code in parallel, the `multiprocessing` library spawns separate
processes on different cores using operating system API calls.

**spawn**  is the default method in MacOS and Windows. It creates child
processes that inherit the resources needed to run the object's `run()` method.
Although slower than other methods (like fork), it provides consistent
execution.

**fork** is the default method in all POSIX systems except MacOS. It creates
child processes with all the context and resources of the parent process. It's
faster than **spawn**, but may encounter issues in multiprocess and
multithreaded environments.

This approach allows us to have a new Python interpreter for each processor,
eliminating the problem of multiple threads contending for the interpreter's
availability.

Given that Point Cloud processing is heavily reliant on CPU performance, we
employ multiprocessing to execute processes in parallel for each chunk of the
Point Cloud being read.

To read large LAS/LAZ files, `laspy` provides the `chunk_iterator` for reading
the Point Cloud in chunks of data that can be sent to different processes for
processing. Subsequently, the processed data is assembled and written back into
another file by chunk. To achieve this, we require two context managers: one
for reading the input file and another for writing the output file.

Here's how you would typically do it:

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

To parallelize this process, we create a `ProcessPoolExecutor` that allows us
to send each execution of the function (where we calculate the normals) to a
separate process. As the processes complete, we collect the results and write
them to the new LAS/LAZ file.

Since we collect the results of the futures in our main process and then write
them to the file, we avoid issues where multiple processes access the same file
simultaneously. If your implementation does not permit this approach, you may
need to use a `lock` to ensure data integrity.

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

There are a lot of things to unpack from this code, like *why are we not using
the chunk object itself?*, *why we are creating an empty `PackedPointRecord`?*.

We will start with the `chunk` object. Without touching the why, the object
itself cannot be send to be processed in a process pool. Because of that, we
have to pull the information that we find important from it. Because we are
calculating the normals, what we need are the X, Y and Z coordinates of the
Chunk, taking into account the offset and the scale specified in the header of
the LAS/LAZ file.

Given that the calculations return us an array of values, that will represent
the X,Y and Z coordinates, the RGB values, The intensity and the
classification, we cannot write that directly into the LAS/LAZ file, we need to
create a `PackedPointRecord` with the format specified in the header, on which
we will store the returned array, and then append them to the LAS/LAZ file.

The LAS/LAZ file, has a header object, on which we store the scale, the offset
and the format of the Point Cloud. This is important because for us to be able
to send information to that file, the format of our values must match the one
specified in the header. In our case, both files have the same header format.
However, if you need to write to files with different versions, the array
format must match the version you are writing to.

To identify the format required to be able to append the results into the
`PackedPointRecord`, you could run the following command,

```log
>>> f.header.point_format.dtype()
```

In this example, we are using Point Format version 3, which has the following
structure:

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

Because we couldn't use this command, to match the dtype of the unpacked future
to the dtype of the header.

```log
>>> result = result.astype(header.point_format.dtype())
```

we had to do the transformation in the following manner,

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

And with all of this put together, we are able to process large Point Clouds in
parallel, using all the resources of our computer.

Even tho is needed a great deal of familiarity with the mentioned packages to
understand and apply the code above, the idea was to tackle one of the common
problems that we have encountered with the processing of our Point Clouds and
share the solutions that we have found for our problems.

In case there is something else needed to be discussed, like a better approach
or if you have doubts and want to know more about the code, don't be afraid to
contact me, I will gladly help in what I can.

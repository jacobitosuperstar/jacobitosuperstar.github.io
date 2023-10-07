---
title: Python Parallellism for Point Cloud Processing
date: 2023-09-29T12:00:00-05:00
draft: true

read_more: Read more...
tags: ["python", "LAS", "LAZ", "PointCloud", "LiDAR"]
categories: ["programming"]
---

LAS and their compressed counterpart LAZ, are propular file formats to store
Point Cloud information, generated normally by LiDAR. LiDAR or light detection
and ranging is a remote sensing technology to measure distances and create
highly accurate 3D maps of objects and landscapes. That Point Cloud information
stored consists mainly of X,Y and Z coordinates, intensity, color,
classification of features, gps time and other custom fields that are given by
the scanner. Those LAS files are composed of millions of points that describe
accuratelly the sensed environment or object, making the analysis of them a
challenge.

One of the fundamental steps to process and analize 3D data, is the Normals
calculation. The normals of the Point Cloud provide information about the
orientation and direction of a surface at each point of the point cloud and are
escential for visualization, object recognition and shape analysis.

We are not going to delve into the how those normals are calculated or which
package you should use to do it, the point of the article is to show you how
do parallel calculations while chunked reading and chunked writting of a
LAS/LAZ file, and how python manages the problems of concurrency and
parallellism.

For this you should have general knowledge of Python, and be very familiar with
`numpy` and `laspy`. This is a shallow swim in the world of parallellism in
Python.

```toml
[packages]
numpy = "==1.26.0"
laspy = {extras = ["lazrs"], version = "==2.5.1"}

[requires]
python_version = "3.10"
```

`laspy` and `numpy` are packages that interact directly with the Python C_API
making them incredibly fast, so there isn't much room to improve the speed of
them without directly interacting without C programming. Because of it, we need
to fin new ways to work with our code in a manner on which we can do things in
parallel or have better processing pipelines, to extrac the full capabilities
of our machine.

As you may or may not know, Python execution is limited by the Global
Interpreter Lock (GIL). The GIL is a mechanism used by the CPython
Interpreter to ensure that only one thread at a time executes Python bytecode,
simplifying the implementation and making the object model of CPython safe
against concurrent access. This implementation, besides simplicity, gives us
two main benefits: one is it easier to create multithreaded programs, two its
single-core, single-process performance.

This begs the questions, Why multithreading if you cannot execute several
threads at the same time then?, Is it possible to execute code in parallel with
Python?

Multithreading is an easy way of making python non blocking execution,
meaning that we can create code that can start several tasks at the same even
tho it can only execute a single task a time. This type of concurrency is
great, when you are making calls to another API or to a database where you are
just waiting around for the most part, but for CPU intensive taks, this
approach has a lot of limitations.

To run Python code in parallel, what is done throught the `multiprocessing`
library is to spawn another process in another core using the operating system
API calls.

**spawn** is the default in MacOS and Windows, where the child process just
inherits the resources necessary to run the object's run() method. Is slower
than other methods (like fork), but more consistent in execution.

**fork** is the default in all the POSIX systems except MacOS, where the child
process has all the context and resources that the parent process has. Is
faster than **spawn**, but is prone to crashes in multiprocess and
multithreaded environments.

What this allows us to do is to have a new Python interpreter for each
processor, eliminating the issue of multiple threads waiting for the
interpreter to be free.

Knowing all of this, because the Point Cloud processing is heavily dependent on
CPU performance, we will use mutiprocessing to run processes in parallel for
each chunk of the point cloud being readed.

To read large LAS/LAZ files, `laspy` has the `chunk_iterator` where the point
cloud is being read by chunks of data that we could send to different process
to be processed and then put them back together in another file with the by
writting them chunk by chunk. To do this, we will need two context managers,
one for the file that we are reading, and another one for the file that we are
writting.

```python

# reading the file
with laspy.open(input_file_name, mode="r") as f:

    # creating a file
    with laspy.open(output_file_name, mode="w", header=header) as o_f:
        # writting or appending the data into the point cloud
        o_f.write_points(point_record)
```



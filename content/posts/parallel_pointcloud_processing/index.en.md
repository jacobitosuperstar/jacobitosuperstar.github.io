---
title: Parallel PointCloud Processing
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
LAS/LAZ file, if needed.

For this you should have general knowledge of Python, and be familiar with
`numpy` and `laspy`. This is a shallow swim in the world of parallellism in
Python.

```toml

[packages]
laspy = {extras = ["lazrs"], version = "==2.5.1"}

[requires]
python_version = "3.10"
```

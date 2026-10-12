---
title: Endava
date: 2022-08-01
draft: false

job_title: Senior Developer
start_date: August 2022
end_date: December 2024
---

### Math Engine (June 2024 - December 2024)

Helped develop a math engine for Quote Sizing and Investment Analysis in Real
State Loans. My main contributions for the project where:

- Creating automatic test generation through the use of test JSON files that
contained the different testing scenarios.

- Multi-objective or optimization space binary search to find the maximum loan
amount and the minimum net operating income for a desired loan amount.

Open Source version of the package in [Go][1]

### Point Cloud (August 2022 - May 2024)

Developed and maintained a PyQt desktop program, with VTK for the 3D
rendering, for annotating point clouds through a graphical interface. My main
contributions to the project where:

- Leading the Python side of the migration of the application from Python 3.2
to Python 3.10, while another member of the team led the PyQt6 and the VTK
migrations, which also meant reworking the event system onto messages and
signals. A major refactor, reconciling the behaviour changes and the
dependency constraints of a compiled, GUI heavy stack.

- Creating and leading the implementation of an event driven architecture for
calculation heavy functionalities, where I diverted the load of the functions
to other cores from the computer through the use of multiprocessing, and other
optimizations at the object creation to diminish the impact on RAM consumption,
which doubled the speed of the software and reduced its RAM usage by 40%.

- Automating the creation of blueprints and other technical drawings from the
point cloud, through the use of a local server, that handled the updates or
changes of the annotated shapes within the Point Cloud.

- Creating a facade for the BOX Cloud SDK, to handle safely multi-threading and
simplifying functionality to our file updates and uploads.

[1]: https://github.com/jacobitosuperstar/go-cre-loan-calculations

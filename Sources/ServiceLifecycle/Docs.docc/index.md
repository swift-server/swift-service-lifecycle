# ``ServiceLifecycle``

A library for cleanly starting up and shutting down applications.

## Overview

Applications often have to orchestrate multiple internal services such as
clients or servers to implement their business logic. Doing this can become
tedious; especially when the APIs of the various services are not interoping nicely
with each other. This library tries to solve this issue by providing a ``Service`` protocol
that services should implement and an orchestrator, the ``ServiceRunner``, that handles
running the various services.

This library is fully based on Swift Structured Concurrency which allows it to
safely orchestrate the individual services in separate child tasks. Furthermore, this library
complements the cooperative task cancellation from Structured Concurrency with a new mechanism called
_graceful shutdown_. Cancellation is indicating the tasks to stop their work as soon as possible
whereas _graceful shutdown_ just indicates them that they should come to an end but it is up
to their business logic if and how to do that.

``ServiceLifecycle`` should be used by both library and application authors to create a seamless experience.
Library authors should conform their services to the ``Service`` protocol and application authors
should use the ``ServiceRunner`` to orchestrate all their services.

## Topics

### Articles

- <doc:How-to-adopt-ServiceLifecycle-in-libraries>
- <doc:How-to-adopt-ServiceLifecycle-in-applications>

### Service protocol

- ``Service``

### Service Runner

- ``ServiceRunner``
- ``ServiceRunnerConfiguration``

### Graceful Shutdown

- ``withGracefulShutdownHandler(operation:onGracefulShutdown:)``

### Errors

- ``ServiceRunnerError``

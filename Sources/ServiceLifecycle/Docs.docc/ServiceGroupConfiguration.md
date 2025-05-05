# ``ServiceLifecycle/ServiceGroupConfiguration``

## Topics

### Creating a service group configuration

- ``init(services:logger:)-([Service],_)``
- ``init(services:logger:)-([ServiceConfiguration],_)``
- ``init(gracefulShutdownSignals:)``

### Creating a new service group configuration with signal handlers

- ``init(services:gracefulShutdownSignals:cancellationSignals:logger:)-([Service],_,_,_)``
- ``init(services:gracefulShutdownSignals:cancellationSignals:logger:)-([ServiceConfiguration],_,_,_)``

### Inspecting the service group services

- ``services``
- ``ServiceConfiguration``

### Inspecting the service group logging

- ``logging``
- ``LoggingConfiguration``
- ``logger``

### Inspecting the service group signal handling

- ``cancellationSignals``
- ``maximumCancellationDuration``
- ``gracefulShutdownSignals``
- ``maximumGracefulShutdownDuration``

# ``ServiceLifecycle/ServiceGroup``

## Topics

### Creating a service group

- ``init(configuration:)``
- ``init(services:gracefulShutdownSignals:cancellationSignals:logger:)``
- ``init(services:configuration:logger:)``

### Adding to a service group

- ``addServiceUnlessShutdown(_:)-r47h``
- ``addServiceUnlessShutdown(_:)-9jpoj``

### Running a service group

- ``run(file:line:)``
- ``run()``
- ``triggerGracefulShutdown()``

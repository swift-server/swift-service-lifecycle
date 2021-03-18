//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Atomics)
#if swift(>=5.1)
@_implementationOnly import Atomics
#else
import Atomics
#endif
#else
import CLifecycleHelpers
#endif

internal class AtomicBoolean {
    #if canImport(Atomics)
    private let managed: ManagedAtomic<Bool>
    #else
    private let unmanaged: UnsafeMutablePointer<c_lifecycle_atomic_bool>
    #endif

    init(_ value: Bool) {
        #if canImport(Atomics)
        self.managed = .init(value)
        #else
        self.unmanaged = c_lifecycle_atomic_bool_create(value)
        #endif
    }

    deinit {
        #if !canImport(Atomics)
        self.unmanaged.deinitialize(count: 1)
        #endif
    }

    func compareAndSwap(expected: Bool, desired: Bool) -> Bool {
        #if canImport(Atomics)
        return self.managed.compareExchange(expected: expected, desired: desired, ordering: .acquiring).exchanged
        #else
        return c_lifecycle_atomic_bool_compare_and_exchange(self.unmanaged, expected, desired)
        #endif
    }
}

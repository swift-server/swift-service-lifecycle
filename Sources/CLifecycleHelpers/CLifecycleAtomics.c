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

#include <CLifecycleAtomics.h>

#include <stdlib.h>
#include <stdatomic.h>

struct c_lifecycle_atomic_bool *c_lifecycle_atomic_bool_create(bool value) {
    struct c_lifecycle_atomic_bool *wrapper = malloc(sizeof(*wrapper));
    atomic_init(&wrapper->value, value);
    return wrapper;
}

bool c_lifecycle_atomic_bool_compare_and_exchange(struct c_lifecycle_atomic_bool *wrapper, bool expected, bool desired) {
    bool expected_copy = expected;
    return atomic_compare_exchange_strong(&wrapper->value, &expected_copy, desired);
}

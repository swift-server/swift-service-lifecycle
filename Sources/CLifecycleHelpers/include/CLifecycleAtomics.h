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

#include <stdbool.h>
#include <stdint.h>

struct c_lifecycle_atomic_bool {
    _Atomic bool value;
};
struct c_lifecycle_atomic_bool * _Nonnull c_lifecycle_atomic_bool_create(bool value);

bool c_lifecycle_atomic_bool_compare_and_exchange(struct c_lifecycle_atomic_bool * _Nonnull atomic, bool expected, bool desired);

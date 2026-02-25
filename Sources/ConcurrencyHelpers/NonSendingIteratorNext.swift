@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncIteratorProtocol {
    @usableFromInline
    package mutating func nonSendingNext() async rethrows -> Element? {
        guard #available(macOS 15.0, *) else {
            // On older Apple platforms, we cannot pass through the isolation
            // That means next() runs on task isolation
            // That is not safe to the compiler, because the caller of this send function may have called
            // it concurrently
            // However, that shouldn't happen in practise since the iterator itself is not Sendable

            nonisolated(unsafe) var this = self
            defer {
                self = this
            }
            return try await this.next()
        }
        return try await self.next(isolation: #isolation)
    }
}

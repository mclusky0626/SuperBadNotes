//
//  ReadWriteLock.swift
//  BadNotes
//
//  읽기는 여럿이 동시에, 쓰기는 혼자.
//  PDF 타일은 여러 스레드가 동시에 그리고(읽기), 페이지를 넣을 때만 잠깐 막음(쓰기).
//

import Foundation

nonisolated final class ReadWriteLock: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
}

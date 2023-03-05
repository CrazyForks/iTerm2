//
//  iTermAtomicMutableArrayOfWeakObjects.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 1/3/23.
//

#import "iTermAtomicMutableArrayOfWeakObjects.h"

extern "C" {
#import "DebugLogging.h"
#import "NSArray+iTerm.h"
#import "iTermWeakBox.h"
}

#include <atomic>

@implementation iTermAtomicMutableArrayOfWeakObjects {
    NSMutableArray<iTermWeakBox *> *_array;
    id _lock;
}

// Sanity check
static std::atomic<int> iTermAtomicMutableArrayOfWeakObjectsLockCount;
static void iTermAtomicMutableArrayOfWeakObjectsLock(void) {
    iTermAtomicMutableArrayOfWeakObjectsLockCount += 1;
    assert(iTermAtomicMutableArrayOfWeakObjectsLockCount == 1);
}
static void iTermAtomicMutableArrayOfWeakObjectsLockUnlock(void) {
    iTermAtomicMutableArrayOfWeakObjectsLockCount -= 1;
    assert(iTermAtomicMutableArrayOfWeakObjectsLockCount == 0);
}

+ (id)lock {
    static dispatch_once_t onceToken;
    static id instance;
    dispatch_once(&onceToken, ^{
        instance = [[NSObject alloc] init];
    });
    return instance;
}

+ (instancetype)array {
    return [[self alloc] init];
}

- (instancetype)init {
    if (self = [super init]) {
        _array = [NSMutableArray array];
    }
    return self;
}

- (void)removeObjectsPassingTest:(BOOL (^)(id anObject))block {
    @synchronized([iTermAtomicMutableArrayOfWeakObjects lock]) {
        iTermAtomicMutableArrayOfWeakObjectsLock();
        @try {
            [_array removeObjectsPassingTest:^(iTermWeakBox *box) {
                return block(box.object);
            }];
        } @catch (NSException *exception) {
            const int count = iTermAtomicMutableArrayOfWeakObjectsLockCount;
            CrashLog(@"%@ with lock count=%@", exception.debugDescription, @(count));
            @throw exception;
        }
        iTermAtomicMutableArrayOfWeakObjectsLockUnlock();
    }
}

- (NSArray *)strongObjects {
    @synchronized([iTermAtomicMutableArrayOfWeakObjects lock]) {
        iTermAtomicMutableArrayOfWeakObjectsLock();
        NSArray *result = [_array mapWithBlock:^(iTermWeakBox *box) { return box.object; }];
        iTermAtomicMutableArrayOfWeakObjectsLockUnlock();
        return result;
    }
}

- (void)removeAllObjects {
    @synchronized([iTermAtomicMutableArrayOfWeakObjects lock]) {
        iTermAtomicMutableArrayOfWeakObjectsLock();
        [_array removeAllObjects];
        iTermAtomicMutableArrayOfWeakObjectsLockUnlock();
    }
}

- (void)addObject:(id)object {
    @synchronized([iTermAtomicMutableArrayOfWeakObjects lock]) {
        iTermAtomicMutableArrayOfWeakObjectsLock();
        [_array addObject:[iTermWeakBox boxFor:object]];
        iTermAtomicMutableArrayOfWeakObjectsLockUnlock();
    }
}

- (NSUInteger)count {
    @synchronized([iTermAtomicMutableArrayOfWeakObjects lock]) {
        iTermAtomicMutableArrayOfWeakObjectsLock();
        const NSUInteger result = _array.count;
        iTermAtomicMutableArrayOfWeakObjectsLockUnlock();
        return result;
    }
}

@end


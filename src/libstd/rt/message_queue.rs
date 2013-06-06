// Copyright 2013 The Rust Project Developers. See the COPYRIGHT
// file at the top-level directory of this distribution and at
// http://rust-lang.org/COPYRIGHT.
//
// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

//! A concurrent queue that supports multiple producers and a single consumer.
//! Note that while any individual task may have to loop several times while pushing there is
//! global progress: whenever you fail to push, somewhere out there there must exist at least one
//! task that succeeded.

use cast::{transmute};
use libc::{malloc,free};
use ops::{Drop};
use option::{Option,Some,None};
use ptr;
use sys::{size_of};
use unstable::intrinsics::{move_val_init,forget};
use unstable::atomics::{AtomicPtr,Acquire,SeqCst};

/// Node that holds a value for the Queue
/// The MessageQueue assumes only the sentinel node may contain 'None'.
priv struct Node<T> {
    value: Option<T>,
    next: AtomicPtr<Node<T>>
}

impl<T> Node<T> {
    fn new() -> Node<T> {
        Node{ value: None, next: AtomicPtr::new(ptr::mut_null()) }
    }
    fn new_with_val(value: T) -> Node<T> {
        Node{ value: Some(value), next: AtomicPtr::new(ptr::mut_null()) }
    }
}

/// A lockless concurrent Queue.
#[mutable]
struct MessageQueue<T> {
    priv head: Node<T>,
    priv tail: AtomicPtr<Node<T>>
}

#[unsafe_destructor]
impl<T> Drop for MessageQueue<T> {
    fn finalize(&self) {
        unsafe {
            let this: &mut MessageQueue<T> = transmute(self);

            let mut node = this.head.load(SeqCst);
            while !ptr::is_null(node) {
                let next = (*node).next.load(SeqCst);
                (*node).value = None;   // Destroy value if applicable.
                free( transmute(node) );
                node = next;
            }
        }
    }
}

impl<T> MessageQueue<T> {
    /// Creates a new MessageQueue.
    pub fn new()-> MessageQueue<T> {
        unsafe {
            // Create a sentinel node.
            let node: *mut Node<T> = transmute(malloc(size_of::<Node<T>>() as u64));
            move_val_init(&mut *node, Node::new());
            MessageQueue{ head: new(node), tail: AtomicPtr::new(node) }
        }
    }

    /// Pushes a value to the end of the MessageQueue.
    pub fn push(&mut self, value: T) {
        unsafe {
            // Create the node that we will insert.
            let node: *mut Node<T> = transmute(malloc(size_of::<Node<T>>() as u64));
            move_val_init(transmute(node),Node::new_with_val(value));
            loop {
                let last = self.tail.load(Acquire);
                let next = (*last).next.load(Acquire);
                if (last == self.tail.load(Acquire)) {
                    if ptr::is_null(next) {
                        // Nobody else has inserted a 'next' node yet, we try to insert it.
                        if ((*last).next.compare_and_swap(next,node,SeqCst) == next) {
                            // And set 'tail' to the new last node.
                            // We don't need to check if this CAS succeeds: if it fails, it means
                            // another task has done it for us.
                            self.tail.compare_and_swap(last,node,SeqCst);
                            return;
                        } else {
                            // Another task was faster. Retry.
                        }
                    } else {
                        // If last->next != null, someone was faster
                        // We help by forwarding last to next.
                        self.tail.compare_and_swap(last, next,SeqCst);
                    }
                }
            }
        }
    }

    /// Pops a value from the MessageQueue.
    /// If there is a value, returns Some<value>. Otherwise returns None.
    pub fn pop(&mut self) -> Option<T> {
        unsafe {
            loop {
                let first = self.head;
                let last = self.tail.load(Acquire);
                let next = (*first).next.load(Acquire);
                if (first == last) {    // Check if there is a node in the queue
                    if next == ptr::mut_null() { // Is someone inserting right now?
                        return None // No, really empty.
                    } else { // If someone is inserting, try to help.
                        self.tail.compare_and_swap(last,next,SeqCst);
                    }
                } else {    // There is a node, we grab it.
                    let mut result = None;
                    ptr::copy_nonoverlapping_memory(&mut result,&((*next).value),1);
                    self.head = next;
                    free( transmute(first) );
                    return result;
                }
            }
        }
    }
}


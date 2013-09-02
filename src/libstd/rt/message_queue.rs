// Copyright 2013 The Rust Project Developers. See the COPYRIGHT
// file at the top-level directory of this distribution and at
// http://rust-lang.org/COPYRIGHT.
//
// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

//! An efficient lock-free multiple-producer/single-consumer queue as described by Dmitriy Vyukov
//! Original version (in C) can be found here:
//! http://www.1024cores.net/home/lock-free-algorithms/queues/non-intrusive-mpsc-node-based-queue

use cast::transmute;
use clone::Clone;
use ops::Drop;
use kinds::Send;
use option::{Option,Some,None};
use ptr::{is_not_null, mut_null};
use unstable::atomics::{AtomicPtr,AcqRel,Acquire,Release};
use unstable::sync::UnsafeArc;
use util::swap;

/// A lockless concurrent Queue.
pub struct MessageQueue<T> {
    priv state: UnsafeArc<State<T>>,
}

#[mutable]
struct State<T> {
    head: AtomicPtr<Node<T>>,
    tail: *mut Node<T>,
}

impl<T: Send> MessageQueue<T> {
    pub fn new() -> MessageQueue<T> {
            // the sentinel node
            let node = unsafe { transmute::<~Node<T>,*mut Node<T>>(~Node::new()) };
            MessageQueue {
                state: UnsafeArc::new(State {
                    head: AtomicPtr::new(node),
                    tail: node
                })
            }
    }

    pub fn push(&self, value: T) {
        unsafe {
            let state = self.state.get();
            let node = transmute::<~Node<T>,*mut Node<T>>(~Node::new());
            (*node).value = Some(value);
            let prev = (*state).head.swap(node, AcqRel);
            (*prev).next.store(node, Release);
        }
    }

    pub fn pop(&self) -> Option<T> {
        unsafe {
            let state = self.state.get();
            let tail = (*state).tail;
            let next = (*tail).next.load(Acquire);
            if is_not_null(next) {
                (*state).tail = next;
                let mut value = None;
                swap(&mut value, &mut (*next).value);   // Get the value.
                let _: ~Node<T> = transmute(tail); // Let drop glue handle the tail.
                value
            } else {
                None
            }
        }
    }

    #[inline]
    pub fn casual_pop(&self) -> Option<T> {
        self.pop()
    }
}

impl<T: Send> Clone for MessageQueue<T> {
    fn clone(&self) -> MessageQueue<T> {
        MessageQueue {
            state: self.state.clone()
        }
    }
}

#[unsafe_destructor]
impl<T: Send> Drop for State<T> {
    fn drop(&self) {
        unsafe {
            let mut node = (*self).tail;
            while is_not_null(node) {
                let next = (*node).next.load(Acquire);
                let _: ~Node<T> = transmute(node);  // Destroy node and contents.
                node = next;
            }
        }
    }
}

struct Node<T> {
    next: AtomicPtr<Node<T>>,
    value: Option<T>,
}

impl<T: Send> Node<T> {
    #[inline]
    fn new() -> Node<T> {
        Node {
            next: AtomicPtr::new( mut_null() ),
            value: None,
        }
    }
}


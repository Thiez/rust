// Copyright 2013 The Rust Project Developers. See the COPYRIGHT
// file at the top-level directory of this distribution and at
// http://rust-lang.org/COPYRIGHT.
//
// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

extern mod extra;

use std::comm::{stream, Port, Chan};
use std::libc::{malloc,free};
use std::rt::message_queue::{MessageQueue};
use std::task::spawn;
use std::uint;
use std::unstable::intrinsics::{transmute,move_val_init,uninit,size_of};

use extra::sort;

fn main() {

    unsafe {
        let mq_ptr: *mut MessageQueue<uint> = // Dirty trick to move the same MessageQueue to
            transmute(malloc(size_of::<MessageQueue<uint>>() as u64)); // several tasks.
        move_val_init(transmute(mq_ptr),MessageQueue::new::<uint>());
        let mut ports = ~[];
        for uint::range(0,4) |n|{
            let (port, chan): (Port<int>, Chan<int>) = stream();
            ports.push(port);
            do spawn {
                for uint::range(0,10000) |i| {
                    (*mq_ptr).push(4*i + n);
                }
                chan.send(0);
            }
        }
        for ports.each |port| { // 'join' with the tasks.
            port.recv();
        }
        
        let mut mq: MessageQueue<uint> = uninit();
        std::unstable::intrinsics::move_val_init(&mut mq,**&mq_ptr);
        free( transmute(mq_ptr) );
        
        let mut values = ~[];
        loop {
            match mq.pop() {
                Some(n) => {values.push(n)},
                None    => break
            }
        }
        sort::quick_sort3(values);
        let mut expected = ~[];
        for uint::range(0,40000) |n| {
            expected.push(n)
        }
        assert_eq!(values.len(), expected.len());
        assert_eq!(values,expected);
    }
}


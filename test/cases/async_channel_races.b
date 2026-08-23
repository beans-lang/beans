import std.async as aio
import std.io
import std.thread
import std.time

async fn receive_value(channel: Channel<int>) -> int {
    return (await channel.receive_async()).or(-9)
}

async fn cancel_receive(
    channel: Channel<int>, gate: aio.Event, marker: int) -> int {
    async let waiting: Option<int> = channel.receive_async()
    await gate.wait()
    return marker
}

async fn send_value(channel: Channel<int>, value: int) -> int {
    await channel.send_async(value)
    return value
}

async fn cancel_send(
    channel: Channel<int>, value: int,
    gate: aio.Event, marker: int) -> int {
    async let waiting: unit = channel.send_async(value)
    await gate.wait()
    return marker
}

async fn wait_started(started: AtomicInt, count: int) {
    for started.load() < count { await aio.yield_now() }
}

async fn receiver_cancellation() {
    // Cancellation unlinks the exact head/middle receiver tickets. The two
    // survivors still receive in FIFO order.
    let receives: Channel<int> = new Channel<int>(1)
    let head_gate: aio.Event = new aio.Event()
    let middle_gate: aio.Event = new aio.Event()
    let receivers: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    receivers.start(cancel_receive(receives, head_gate, -1))
    receivers.start(receive_value(receives))
    receivers.start(cancel_receive(receives, middle_gate, -2))
    receivers.start(receive_value(receives))
    let receive_blocked: Option<int> = receivers.try_next()
    head_gate.set()
    middle_gate.set()
    let canceled_head: int = (await receivers.next()).or(0)
    let canceled_middle: int = (await receivers.next()).or(0)
    let producer: Thread<int> = thread.spawn(fn() -> int {
        receives.send(11)
        receives.send(22)
        return 2
    })
    let received: List<int> = await receivers.wait_all()
    io.println("receive cancel {canceled_head} {canceled_middle} fifo {received[0]} {received[1]} worker {producer.join()}")
}

async fn sender_cancellation() {
    // The same exact unlink rule applies to blocked sender tickets.
    let sends: Channel<int> = new Channel<int>(1)
    sends.send(0)
    let send_head_gate: aio.Event = new aio.Event()
    let send_middle_gate: aio.Event = new aio.Event()
    let senders: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    senders.start(cancel_send(sends, 1, send_head_gate, -1))
    senders.start(send_value(sends, 2))
    senders.start(cancel_send(sends, 3, send_middle_gate, -2))
    senders.start(send_value(sends, 4))
    let send_blocked: Option<int> = senders.try_next()
    send_head_gate.set()
    send_middle_gate.set()
    let send_canceled_head: int = (await senders.next()).or(0)
    let send_canceled_middle: int = (await senders.next()).or(0)
    let consumer: Thread<int> = thread.spawn(fn() -> int {
        var packed: int = 0
        for i: int in 0..3 {
            packed = packed * 10 + sends.receive().or(9)
        }
        return packed
    })
    let sent: List<int> = await senders.wait_all()
    io.println("send cancel {send_canceled_head} {send_canceled_middle} fifo {sent[0]} {sent[1]} seen {consumer.join()}")
}

async fn mixed_cancellation() {
    // A sync receiver can sit behind an async head. Canceling that head must
    // wake the host waiter even when a value is already buffered.
    let mixed_receive: Channel<int> = new Channel<int>(1)
    let mixed_receive_gate: aio.Event = new aio.Event()
    let mixed_receive_group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    mixed_receive_group.start(cancel_receive(
        mixed_receive, mixed_receive_gate, -3))
    let mixed_receive_pending: Option<int> =
        mixed_receive_group.try_next()
    let mixed_receive_started: AtomicInt = new AtomicInt(0)
    let sync_receiver: Thread<int> = thread.spawn(fn() -> int {
        mixed_receive_started.store(1)
        return mixed_receive.receive().or(-9)
    })
    await wait_started(mixed_receive_started, 1)
    mixed_receive.send(31)
    mixed_receive_gate.set()
    let mixed_receive_cancel: int =
        (await mixed_receive_group.next()).or(0)
    io.println("mixed receive {mixed_receive_cancel} {sync_receiver.join()}")

    // Mirror the race for a sync sender behind a canceled async head.
    let mixed_send: Channel<int> = new Channel<int>(2)
    mixed_send.send(0)
    mixed_send.send(1)
    let mixed_send_gate: aio.Event = new aio.Event()
    let mixed_send_group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    mixed_send_group.start(cancel_send(
        mixed_send, 2, mixed_send_gate, -4))
    let mixed_send_pending: Option<int> = mixed_send_group.try_next()
    let mixed_send_started: AtomicInt = new AtomicInt(0)
    let sync_sender: Thread<int> = thread.spawn(fn() -> int {
        mixed_send_started.store(1)
        mixed_send.send(3)
        return 3
    })
    await wait_started(mixed_send_started, 1)
    let mixed_first: int = mixed_send.receive().or(-9)
    mixed_send_gate.set()
    let mixed_send_cancel: int =
        (await mixed_send_group.next()).or(0)
    let mixed_sender_value: int = sync_sender.join()
    io.println("mixed send {mixed_send_cancel} {mixed_first} {mixed_send.receive().or(-9)} {mixed_send.receive().or(-9)} worker {mixed_sender_value}")
}

async fn roomy_fanout() {
    // Capacity greater than one needs same-side wake fan-out after an async
    // commit, otherwise both sync waiters can remain asleep behind old head.
    let roomy_send: Channel<int> = new Channel<int>(3)
    roomy_send.send(0)
    roomy_send.send(1)
    roomy_send.send(2)
    let roomy_senders: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    roomy_senders.start(send_value(roomy_send, 3))
    let roomy_send_pending: Option<int> = roomy_senders.try_next()
    let roomy_send_started: AtomicInt = new AtomicInt(0)
    let roomy_sender_a: Thread<int> = thread.spawn(fn() -> int {
        roomy_send_started.add_and_get(1)
        roomy_send.send(4)
        return 4
    })
    let roomy_sender_b: Thread<int> = thread.spawn(fn() -> int {
        roomy_send_started.add_and_get(1)
        roomy_send.send(5)
        return 5
    })
    await wait_started(roomy_send_started, 2)
    let old_sum: int = roomy_send.receive().or(0) +
                       roomy_send.receive().or(0) +
                       roomy_send.receive().or(0)
    let async_sent: int = (await roomy_senders.next()).or(0)
    let host_send_sum: int = roomy_sender_a.join() + roomy_sender_b.join()
    let first_new: int = roomy_send.receive().or(0)
    let other_new_sum: int = roomy_send.receive().or(0) +
                             roomy_send.receive().or(0)
    io.println("roomy send {old_sum} {async_sent} {host_send_sum} {first_new} {other_new_sum}")

    let roomy_receive: Channel<int> = new Channel<int>(3)
    let roomy_receivers: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    roomy_receivers.start(receive_value(roomy_receive))
    let roomy_receive_pending: Option<int> = roomy_receivers.try_next()
    let roomy_receive_started: AtomicInt = new AtomicInt(0)
    let roomy_receiver_a: Thread<int> = thread.spawn(fn() -> int {
        roomy_receive_started.add_and_get(1)
        return roomy_receive.receive().or(0)
    })
    let roomy_receiver_b: Thread<int> = thread.spawn(fn() -> int {
        roomy_receive_started.add_and_get(1)
        return roomy_receive.receive().or(0)
    })
    await wait_started(roomy_receive_started, 2)
    roomy_receive.send(7)
    roomy_receive.send(8)
    roomy_receive.send(9)
    let async_received: int = (await roomy_receivers.next()).or(0)
    let host_receive_sum: int =
        roomy_receiver_a.join() + roomy_receiver_b.join()
    io.println("roomy receive {async_received} {host_receive_sum}")
}

async fn cross_thread_close() {
    // Close from a host thread wakes every blocked async receiver.
    let closing: Channel<int> = new Channel<int>(1)
    let closing_group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    closing_group.start(receive_value(closing))
    closing_group.start(receive_value(closing))
    let close_pending: Option<int> = closing_group.try_next()
    let closer: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_millis(10)
        closing.close()
        return 1
    })
    let closed: List<int> = await closing_group.wait_all()
    io.println("cross close {closed[0]} {closed[1]} {closer.join()}")
}

async fn main() {
    await receiver_cancellation()
    await sender_cancellation()
    await mixed_cancellation()
    await roomy_fanout()
    await cross_thread_close()
}

// Focused process and datagram payload benchmark. Both rows use only public APIs.
import std.io
import std.net
import std.os
import std.process
import std.time

fn process_payload(size: int, rounds: int) {
    var checksum: int = 0
    let started: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        var command: process.Command = new process.Command("/usr/bin/head")
        command.arg("-c").arg("{size}").arg("/dev/zero")
        command.capture_limit(size)
        let output: process.Output = command.run().expect("process payload")
        checksum += output.out.len() + output.err.len() + output.status
    }
    io.println("payload process {size} {rounds} {time.monotonic_nanos() - started} {checksum}")
}

fn datagram_payload(size: int, rounds: int) {
    let receiver: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0).expect("receiver")
    let sender: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0).expect("sender")
    receiver.set_timeouts(5000, 5000).expect("receiver timeout")
    sender.set_timeouts(5000, 5000).expect("sender timeout")
    let destination: net.Address = receiver.local_address().expect("address")
    let payload: Bytes = new Bytes(size).fill(113)
    var checksum: int = 0
    let started: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        checksum += sender.send_to(payload, destination).expect("send")
        let received: net.Datagram = receiver.recv_from(size).expect("receive")
        checksum += received.data.len()
        checksum += received.data.get(round % size)
    }
    io.println("payload datagram {size} {rounds} {time.monotonic_nanos() - started} {checksum}")
}

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("process")
    if mode == "process" {
        process_payload(args.get(1).or("").to_int().or(16777216),
                        args.get(2).or("").to_int().or(2))
    } else if mode == "datagram" {
        datagram_payload(args.get(1).or("").to_int().or(8192),
                         args.get(2).or("").to_int().or(10000))
    } else {
        io.eprintln("mode must be process or datagram")
        os.exit(2)
    }
}

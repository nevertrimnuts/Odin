// +build windows
/*
	Copyright 2022 Tetralux        <tetraluxonpc@gmail.com>
	Copyright 2022 Colin Davidson  <colrdavidson@gmail.com>
	Copyright 2022 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-3 license.

	List of contributors:
		Tetralux:        Initial implementation
		Colin Davidson:  Linux platform code, OSX platform code, Odin-native DNS resolver
		Jeroen van Rijn: Cross platform unification, code style, documentation
*/

/*
	Package net implements cross-platform Berkeley Sockets, DNS resolution and associated procedures.
	For other protocols and their features, see subdirectories of this package.
*/
package net

import "core:c"
import win "core:sys/windows"
import "core:time"

Platform_Socket :: win.SOCKET

@(init, private)
ensure_winsock_initialized :: proc() {
	win.ensure_winsock_initialized()
}

create_socket :: proc(family: Address_Family, protocol: Socket_Protocol) -> (socket: Any_Socket, err: Network_Error) {
	c_type, c_protocol, c_family: c.int

	switch family {
	case .IP4:  c_family = win.AF_INET
	case .IP6:  c_family = win.AF_INET6
	case:
		unreachable()
	}

	switch protocol {
	case .TCP:  c_type = win.SOCK_STREAM; c_protocol = win.IPPROTO_TCP
	case .UDP:  c_type = win.SOCK_DGRAM;  c_protocol = win.IPPROTO_UDP
	case:
		unreachable()
	}

	sock := win.socket(c_family, c_type, c_protocol)
	if sock == win.INVALID_SOCKET {
		err = Create_Socket_Error(win.WSAGetLastError())
		return
	}

	switch protocol {
	case .TCP:  return TCP_Socket(sock), nil
	case .UDP:  return UDP_Socket(sock), nil
	case:
		unreachable()
	}
}

dial_tcp_from_endpoint :: proc(endpoint: Endpoint, options := default_tcp_options) -> (skt: TCP_Socket, err: Network_Error) {
	if endpoint.port == 0 {
		err = .Port_Required
		return
	}

	family := family_from_endpoint(endpoint)
	sock := create_socket(family, .TCP) or_return
	skt = sock.(TCP_Socket)

	// NOTE(tetra): This is so that if we crash while the socket is open, we can
	// bypass the cooldown period, and allow the next run of the program to
	// use the same address immediately.
	_ = set_option(skt, .Reuse_Address, true)

	sockaddr := _endpoint_to_sockaddr(endpoint)
	res := win.connect(Platform_Socket(skt), &sockaddr, size_of(sockaddr))
	if res < 0 {
		err = Dial_Error(win.WSAGetLastError())
		return
	}

	if options.no_delay {
		_ = set_option(sock, .TCP_Nodelay, true) // NOTE(tetra): Not vital to succeed; error ignored
	}

	return
}

bind :: proc(skt: Any_Socket, ep: Endpoint) -> (err: Network_Error) {
	sockaddr := _endpoint_to_sockaddr(ep)
	s := any_socket_to_socket(skt)
	res := win.bind(Platform_Socket(s), &sockaddr, size_of(sockaddr))
	if res < 0 {
		err = Bind_Error(win.WSAGetLastError())
	}
	return
}


// This type of socket becomes bound when you try to send data.
// This is likely what you want if you want to send data unsolicited.
//
// This is like a client TCP socket, except that it can send data to any remote endpoint without needing to establish a connection first.
make_unbound_udp_socket :: proc(family: Address_Family) -> (skt: UDP_Socket, err: Network_Error) {
	sock := create_socket(family, .UDP) or_return
	skt = sock.(UDP_Socket)
	return
}

// This type of socket is bound immediately, which enables it to receive data on the port.
// Since it's UDP, it's also able to send data without receiving any first.
//
// This is like a listening TCP socket, except that data packets can be sent and received without needing to establish a connection first.
//
// The bound_address is the address of the network interface that you want to use, or a loopback address if you don't care which to use.
make_bound_udp_socket :: proc(bound_address: Address, port: int) -> (skt: UDP_Socket, err: Network_Error) {
	skt = make_unbound_udp_socket(family_from_address(bound_address)) or_return
	bind(skt, {bound_address, port}) or_return
	return
}

listen_tcp :: proc(interface_endpoint: Endpoint, backlog := 1000) -> (skt: TCP_Socket, err: Network_Error) {
	assert(backlog > 0 && i32(backlog) < max(i32))

	family := family_from_endpoint(interface_endpoint)
	sock := create_socket(family, .TCP) or_return
	skt = sock.(TCP_Socket)

	// NOTE(tetra): While I'm not 100% clear on it, my understanding is that this will
	// prevent hijacking of the server's endpoint by other applications.
	set_option(skt, .Exclusive_Addr_Use, true) or_return

	bind(sock, interface_endpoint) or_return

	res := win.listen(Platform_Socket(skt), i32(backlog))
	if res == win.SOCKET_ERROR {
		err = Listen_Error(win.WSAGetLastError())
		return
	}

	return
}

accept_tcp :: proc(sock: TCP_Socket, options := default_tcp_options) -> (client: TCP_Socket, source: Endpoint, err: Network_Error) {
	for {
		sockaddr: win.SOCKADDR_STORAGE_LH
		sockaddrlen := c.int(size_of(sockaddr))
		client_sock := win.accept(Platform_Socket(sock), &sockaddr, &sockaddrlen)
		if int(client_sock) == win.SOCKET_ERROR {
			e := win.WSAGetLastError()
			if e == win.WSAECONNRESET {
				// NOTE(tetra): Reset just means that a client that connection immediately lost the connection.
				// There's no need to concern the user with this, so we handle it for them.
				// On Linux, this error isn't possible in the first place according the man pages, so we also
				// can do this to match the behaviour.
				continue
			}
			err = Accept_Error(e)
			return
		}
		client = TCP_Socket(client_sock)
		source = _sockaddr_to_endpoint(&sockaddr)
		if options.no_delay {
			_ = set_option(client, .TCP_Nodelay, true) // NOTE(tetra): Not vital to succeed; error ignored
		}
		return
	}
}

close :: proc(skt: Any_Socket) {
	if s := any_socket_to_socket(skt); s != {} {
		win.closesocket(Platform_Socket(s))
	}
}

recv_tcp :: proc(skt: TCP_Socket, buf: []byte) -> (bytes_read: int, err: Network_Error) {
	if len(buf) <= 0 {
		return
	}
	res := win.recv(Platform_Socket(skt), raw_data(buf), c.int(len(buf)), 0)
	if res < 0 {
		err = TCP_Recv_Error(win.WSAGetLastError())
		return
	}
	return int(res), nil
}

recv_udp :: proc(skt: UDP_Socket, buf: []byte) -> (bytes_read: int, remote_endpoint: Endpoint, err: Network_Error) {
	if len(buf) <= 0 {
		return
	}

	from: win.SOCKADDR_STORAGE_LH
	fromsize := c.int(size_of(from))
	res := win.recvfrom(Platform_Socket(skt), raw_data(buf), c.int(len(buf)), 0, &from, &fromsize)
	if res < 0 {
		err = UDP_Recv_Error(win.WSAGetLastError())
		return
	}

	bytes_read = int(res)
	remote_endpoint = _sockaddr_to_endpoint(&from)
	return
}

recv :: proc{recv_tcp, recv_udp}

// Repeatedly sends data until the entire buffer is sent.
// If a send fails before all data is sent, returns the amount
// sent up to that point.
send_tcp :: proc(skt: TCP_Socket, buf: []byte) -> (bytes_written: int, err: Network_Error) {
	for bytes_written < len(buf) {
		limit := min(int(max(i32)), len(buf) - bytes_written)
		remaining := buf[bytes_written:]
		res := win.send(Platform_Socket(skt), raw_data(remaining), c.int(limit), 0)
		if res < 0 {
			err = TCP_Send_Error(win.WSAGetLastError())
			return
		}
		bytes_written += int(res)
	}
	return
}


// Sends a single UDP datagram packet.
//
// Datagrams are limited in size; attempting to send more than this limit at once will result in a Message_Too_Long error.
// UDP packets are not guarenteed to be received in order.
send_udp :: proc(skt: UDP_Socket, buf: []byte, to: Endpoint) -> (bytes_written: int, err: Network_Error) {
	if len(buf) > int(max(c.int)) {
		// NOTE(tetra): If we don't guard this, we'll return (0, nil) instead, which is misleading.
		err = .Message_Too_Long
		return
	}
	toaddr := _endpoint_to_sockaddr(to)
	res := win.sendto(Platform_Socket(skt), raw_data(buf), c.int(len(buf)), 0, &toaddr, size_of(toaddr))
	if res < 0 {
		err = UDP_Send_Error(win.WSAGetLastError())
		return
	}
	bytes_written = int(res)
	return
}

send :: proc{send_tcp, send_udp}

shutdown :: proc(skt: Any_Socket, manner: Shutdown_Manner) -> (err: Network_Error) {
	s := any_socket_to_socket(skt)
	res := win.shutdown(Platform_Socket(s), c.int(manner))
	if res < 0 {
		return Shutdown_Error(win.WSAGetLastError())
	}
	return
}

set_option :: proc(s: Any_Socket, option: Socket_Option, value: any, loc := #caller_location) -> Network_Error {
	level := win.SOL_SOCKET if option != .TCP_Nodelay else win.IPPROTO_TCP

	bool_value: b32
	int_value: i32
	linger_value: win.LINGER

	ptr: rawptr
	len: c.int

	switch option {
	case
		.Reuse_Address,
		.Exclusive_Addr_Use,
		.Keep_Alive,
		.Out_Of_Bounds_Data_Inline,
		.TCP_Nodelay,
		.Broadcast,
		.Conditional_Accept,
		.Dont_Linger:
			switch x in value {
			case bool, b8:
				x2 := x
				bool_value = b32((^bool)(&x2)^)
			case b16:
				bool_value = b32(x)
			case b32:
				bool_value = b32(x)
			case b64:
				bool_value = b32(x)
			case:
				panic("set_option() value must be a boolean here", loc)
			}
			ptr = &bool_value
			len = size_of(bool_value)
	case .Linger:
		t, ok := value.(time.Duration)
		if !ok do panic("set_option() value must be a time.Duration here", loc)

		num_secs := i64(time.duration_seconds(t))
		if time.Duration(num_secs * 1e9) != t do return .Linger_Only_Supports_Whole_Seconds
		if num_secs > i64(max(u16)) do return .Value_Out_Of_Range
		linger_value.l_onoff = 1
		linger_value.l_linger = c.ushort(num_secs)

		ptr = &linger_value
		len = size_of(linger_value)
	case
		.Receive_Timeout,
		.Send_Timeout:
			t, ok := value.(time.Duration)
			if !ok do panic("set_option() value must be a time.Duration here", loc)

			int_value = i32(time.duration_milliseconds(t))
			ptr = &int_value
			len = size_of(int_value)

	case
		.Receive_Buffer_Size,
		.Send_Buffer_Size:
			switch i in value {
			case  i8,    u8: i2 := i; int_value = c.int((^u8)(&i2)^)
			case  i16,  u16: i2 := i; int_value = c.int((^u16)(&i2)^)
			case  i32,  u32: i2 := i; int_value = c.int((^u32)(&i2)^)
			case  i64,  u64: i2 := i; int_value = c.int((^u64)(&i2)^)
			case i128, u128: i2 := i; int_value = c.int((^u128)(&i2)^)
			case  int, uint: i2 := i; int_value = c.int((^uint)(&i2)^)
			case:
				panic("set_option() value must be an integer here", loc)
			}
			ptr = &int_value
			len = size_of(int_value)
	}

	skt := any_socket_to_socket(s)
	res := win.setsockopt(Platform_Socket(skt), c.int(level), c.int(option), ptr, len)
	if res < 0 {
		return Socket_Option_Error(win.WSAGetLastError())
	}

	return nil
}


@(private)
_endpoint_to_sockaddr :: proc(ep: Endpoint) -> (sockaddr: win.SOCKADDR_STORAGE_LH) {
	switch a in ep.address {
	case IP4_Address:
		(^win.sockaddr_in)(&sockaddr)^ = win.sockaddr_in {
			sin_port = u16be(win.USHORT(ep.port)),
			sin_addr = transmute(win.in_addr) a,
			sin_family = u16(win.AF_INET),
		}
		return
	case IP6_Address:
		(^win.sockaddr_in6)(&sockaddr)^ = win.sockaddr_in6 {
			sin6_port = u16be(win.USHORT(ep.port)),
			sin6_addr = transmute(win.in6_addr) a,
			sin6_family = u16(win.AF_INET6),
		}
		return
	}
	unreachable()
}

@(private)
_sockaddr_to_endpoint :: proc(native_addr: ^win.SOCKADDR_STORAGE_LH) -> (ep: Endpoint) {
	switch native_addr.ss_family {
	case u16(win.AF_INET):
		addr := cast(^win.sockaddr_in) native_addr
		port := int(addr.sin_port)
		ep = Endpoint {
			address = IP4_Address(transmute([4]byte) addr.sin_addr),
			port = port,
		}
	case u16(win.AF_INET6):
		addr := cast(^win.sockaddr_in6) native_addr
		port := int(addr.sin6_port)
		ep = Endpoint {
			address = IP6_Address(transmute([8]u16be) addr.sin6_addr),
			port = port,
		}
	case:
		panic("native_addr is neither IP4 or IP6 address")
	}
	return
}
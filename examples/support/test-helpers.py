#!/usr/bin/env python3
"""Exercise example executables through their public process/socket interfaces."""
import socket
import subprocess
import sys
import threading
import unittest
from pathlib import Path

BIN = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'target/debug/examples').resolve()


class Helpers(unittest.TestCase):
    def start(self, name, *args):
        p = subprocess.Popen([str(BIN / name), *map(str, args)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def cleanup():
            p.terminate()
            p.communicate(timeout=5)
        self.addCleanup(cleanup)
        return p

    def test_origin_request_reject_and_reserve(self):
        port = int(subprocess.check_output([str(BIN / 'e2e_origin'), 'reserve-port']))
        self.assertNotIn(port, (0, 7899))
        for args, status, marker in [((), b'200 OK', 'REQUEST'), (('reject',), b'403 Forbidden', 'REJECT')]:
            p = self.start('e2e_origin', *args)
            port = int(p.stdout.readline().strip().split('=')[1])
            with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                s.sendall(b'GET /nonce-1 HTTP/1.1\r\nHost: localhost\r\n\r\n')
                response = b''
                while chunk := s.recv(4096):
                    response += chunk
            self.assertIn(status, response)
            self.assertEqual(p.stdout.readline().strip(), f'E2E_ORIGIN_{marker}=/nonce-1')
            self.assertIn(b'zc-e2e-origin:nonce-1' if not args else b'forbidden', response)

    def test_origin_eof_response_waits_for_half_close(self):
        p = self.start('e2e_origin', 'eof-response')
        port = int(p.stdout.readline().strip().split('=')[1])
        with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
            s.sendall(b'NEEDS_EOF')
            s.shutdown(socket.SHUT_WR)
            self.assertEqual(s.recv(64), b'EOF-RESPONSE')
        self.assertEqual(p.stdout.readline().strip(), 'E2E_EOF_ORIGIN_RESPONSE=PASS')

    def test_obfs_exact_length_and_half_close_attestation(self):
        for mode in ['fragmented_header', 'same_write_tail']:
            backend = socket.socket()
            backend.bind(('127.0.0.1', 0))
            backend.listen()
            backend.settimeout(3)
            self.addCleanup(backend.close)
            p = self.start('e2e_obfs_oracle', backend.getsockname()[1], 'alias.test', 3, mode, 'oracle')
            port = int(p.stdout.readline().strip().split(':')[1])
            self.assertEqual(p.stdout.readline().strip(), f'E2E_OBFS_ORACLE_EXPECTED=oracle:host=alias.test:body=3:mode={mode}')
            def header(length):
                return (f'GET / HTTP/1.1\r\nHost: alias.test:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nContent-Length: {length}\r\n\r\n').encode()
            for count, length in enumerate([2, 4], 1):
                with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                    s.sendall(header(length))
                    self.assertEqual(s.recv(1), b'')
                self.assertEqual(p.stdout.readline().strip(), f'E2E_OBFS_ORACLE_RAW_ACCEPTED=oracle:{count}')
                self.assertEqual(p.stdout.readline().strip(), f'E2E_OBFS_ORACLE_REJECTED=oracle:raw={count}:verified=0:error=ContentLengthMismatch')
            received = []
            def respond():
                with backend.accept()[0] as b:
                    b.settimeout(3)
                    data = b''
                    while chunk := b.recv(1024):
                        data += chunk
                    received.append(data)
                    b.sendall(b'TAIL')
                    b.shutdown(socket.SHUT_WR)
            worker = threading.Thread(target=respond)
            worker.start()
            with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
                s.sendall(header(3) + b'abcRAW')
                s.shutdown(socket.SHUT_WR)
                response = b''
                while chunk := s.recv(1024):
                    response += chunk
            worker.join(timeout=5)
            self.assertFalse(worker.is_alive())
            self.assertEqual(received, [b'abcRAW'])
            self.assertTrue(response.startswith(b'HTTP/1.1 101 Switching Protocols\r\n'))
            self.assertTrue(response.endswith(b'\r\n\r\nTAIL'))
            self.assertEqual(p.stdout.readline().strip(), 'E2E_OBFS_ORACLE_RAW_ACCEPTED=oracle:3')
            self.assertEqual(p.stdout.readline().strip(), 'E2E_OBFS_ORACLE_VERIFIED=oracle:1')
            self.assertEqual(p.stdout.readline().strip(), 'E2E_OBFS_ORACLE_REQUEST=oracle:GET_HOST_UPGRADE_CONNECTION_KEY_CONTENT_LENGTH_EXACT:3')
            self.assertEqual(p.stdout.readline().strip(), f'E2E_OBFS_ORACLE_RESPONSE=oracle:{mode}')
            self.assertEqual(p.stdout.readline().strip(), 'E2E_OBFS_ORACLE_FORWARD=oracle:RAW_TCP_HALF_CLOSE_PASS')

    def test_udp_independent_vectors_health_and_packet_recovery(self):
        output = subprocess.check_output([str(BIN / 'e2e_ss_udp_oracle'), 'selftest'], text=True, timeout=10)
        self.assertIn('E2E_SS_UDP_SELFTEST=PASS', output)
        p = self.start('e2e_ss_udp_oracle', 'serve', 'aes-128-gcm', 'oracle-vector-password-v1', 'bad-tag-once', 'test', 0)
        port = int(p.stdout.readline().strip().split(':')[1])
        output = subprocess.check_output([str(BIN / 'e2e_ss_udp_oracle'), 'health', str(port), 'test'], text=True, timeout=3)
        self.assertEqual(output.strip(), 'E2E_SS_UDP_HEALTH_PASS=test')
        wire = bytes.fromhex('f0e0d0c0b0a090807060504030201000fcdb69b1dd02167b6b5fb4e6aa16d75c8656108cc2879ee2a02bee68cf79ad110458a788b1b9f090df')
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(0.35)
            s.sendto(wire[:-1] + bytes([wire[-1] ^ 1]), ('127.0.0.1', port))
            with self.assertRaises(socket.timeout):
                s.recv(65536)
            self.assertEqual(p.stdout.readline().strip(), 'E2E_SS_UDP_ORACLE_RAW=test:1')
            s.settimeout(3)
            for count, kind in [(2, 'BAD_TAG'), (3, 'NORMAL')]:
                s.sendto(wire, ('127.0.0.1', port))
                response, peer = s.recvfrom(65536)
                self.assertEqual(peer, ('127.0.0.1', port))
                self.assertEqual(len(response), len(wire))
                for marker in [f'RAW=test:{count}', f'VERIFIED=test:{count}', f'RESPONSE=test:{count}:{kind}']:
                    self.assertEqual(p.stdout.readline().strip(), 'E2E_SS_UDP_ORACLE_' + marker)
        for family, af, ip in [('ipv4', socket.AF_INET, '127.0.0.1'), ('ipv6', socket.AF_INET6, '::1')]:
            p = self.start('e2e_ss_udp_oracle', 'echo', family, 0)
            port = int(p.stdout.readline().strip().split(':')[1])
            with socket.socket(af, socket.SOCK_DGRAM) as s:
                s.settimeout(3)
                s.sendto(b'echo-nonce', (ip, port))
                self.assertEqual(s.recv(1024), b'echo-nonce')
            self.assertEqual(p.stdout.readline().strip(), f'E2E_UDP_ECHO_PACKET={family}:1')


if __name__ == '__main__':
    unittest.main()

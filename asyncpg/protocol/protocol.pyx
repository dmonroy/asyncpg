# Copyright (C) 2016-present the asyncpg authors and contributors
# <see AUTHORS file>
#
# This module is part of asyncpg and is released under
# the Apache 2.0 License: http://www.apache.org/licenses/LICENSE-2.0


# cython: language_level=3

cimport cython
cimport cpython

import asyncio
import builtins
import codecs
import collections
import socket
import time

from libc.stdint cimport int8_t, uint8_t, int16_t, uint16_t, \
                         int32_t, uint32_t, int64_t, uint64_t

from asyncpg.protocol cimport record

from asyncpg.protocol.python cimport (
                     PyMem_Malloc, PyMem_Realloc, PyMem_Calloc, PyMem_Free,
                     PyMemoryView_GET_BUFFER, PyMemoryView_Check,
                     PyMemoryView_FromMemory, PyMemoryView_GetContiguous,
                     PyUnicode_AsUTF8AndSize, PyByteArray_AsString,
                     PyByteArray_Check, PyUnicode_AsUCS4Copy,
                     PyByteArray_Size, PyByteArray_Resize,
                     PyByteArray_FromStringAndSize,
                     PyUnicode_FromKindAndData, PyUnicode_4BYTE_KIND)

from cpython cimport PyBuffer_FillInfo, PyBytes_AsString

from asyncpg.exceptions import _base as apg_exc_base
from asyncpg import compat
from asyncpg import types as apg_types
from asyncpg import exceptions as apg_exc

from asyncpg.protocol cimport hton

include "consts.pxi"
include "pgtypes.pxi"

include "encodings.pyx"
include "settings.pyx"
include "buffer.pyx"

include "codecs/base.pyx"
include "codecs/textutils.pyx"

# String types.  Need to go first, as other codecs may rely on
# text decoding/encoding.
include "codecs/bytea.pyx"
include "codecs/text.pyx"

# Builtin types, in lexicographical order.
include "codecs/bits.pyx"
include "codecs/datetime.pyx"
include "codecs/float.pyx"
include "codecs/geometry.pyx"
include "codecs/int.pyx"
include "codecs/json.pyx"
include "codecs/money.pyx"
include "codecs/network.pyx"
include "codecs/numeric.pyx"
include "codecs/tsearch.pyx"
include "codecs/txid.pyx"
include "codecs/uuid.pyx"

# Various pseudotypes and system types
include "codecs/misc.pyx"

# nonscalar
include "codecs/array.pyx"
include "codecs/range.pyx"
include "codecs/record.pyx"

# contrib
include "codecs/hstore.pyx"

include "coreproto.pyx"
include "prepared_stmt.pyx"


NO_TIMEOUT = object()


cdef class BaseProtocol(CoreProtocol):
    def __init__(self, addr, connected_fut, con_params, loop):
        # type of `con_params` is `_ConnectionParameters`
        CoreProtocol.__init__(self, con_params)

        self.loop = loop
        self.waiter = connected_fut
        self.cancel_waiter = None
        self.cancel_sent_waiter = None

        self.address = addr
        self.settings = ConnectionSettings((self.address, con_params.database))

        self.statement = None
        self.return_extra = False

        self.last_query = None

        self.closing = False
        self.is_reading = True
        self.writing_allowed = asyncio.Event(loop=self.loop)
        self.writing_allowed.set()

        self.timeout_handle = None
        self.timeout_callback = self._on_timeout
        self.completed_callback = self._on_waiter_completed

        self.queries_count = 0

        try:
            self.create_future = loop.create_future
        except AttributeError:
            self.create_future = self._create_future_fallback

    def set_connection(self, connection):
        self.connection = connection

    def get_server_pid(self):
        return self.backend_pid

    def get_settings(self):
        return self.settings

    def is_in_transaction(self):
        # PQTRANS_INTRANS = idle, within transaction block
        # PQTRANS_INERROR = idle, within failed transaction
        return self.xact_status in (PQTRANS_INTRANS, PQTRANS_INERROR)

    cdef inline resume_reading(self):
        if not self.is_reading:
            self.is_reading = True
            self.transport.resume_reading()

    cdef inline pause_reading(self):
        if self.is_reading:
            self.is_reading = False
            self.transport.pause_reading()

    async def prepare(self, stmt_name, query, timeout):
        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()
        timeout = self._get_timeout_impl(timeout)

        self._prepare(stmt_name, query)
        self.last_query = query
        self.statement = PreparedStatementState(stmt_name, query, self)

        return await self._new_waiter(timeout)

    async def bind_execute(self, PreparedStatementState state, args,
                           str portal_name, int limit, return_extra,
                           timeout):

        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()
        timeout = self._get_timeout_impl(timeout)

        self._bind_execute(
            portal_name,
            state.name,
            state._encode_bind_msg(args),
            limit)

        self.last_query = state.query
        self.statement = state
        self.return_extra = return_extra
        self.queries_count += 1

        return await self._new_waiter(timeout)

    async def bind_execute_many(self, PreparedStatementState state, args,
                                str portal_name, timeout):

        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()
        timeout = self._get_timeout_impl(timeout)

        # Make sure the argument sequence is encoded lazily with
        # this generator expression to keep the memory pressure under
        # control.
        data_gen = (state._encode_bind_msg(b) for b in args)
        arg_bufs = iter(data_gen)

        waiter = self._new_waiter(timeout)

        self._bind_execute_many(
            portal_name,
            state.name,
            arg_bufs)

        self.last_query = state.query
        self.statement = state
        self.return_extra = False
        self.queries_count += 1

        return await waiter

    async def bind(self, PreparedStatementState state, args,
                   str portal_name, timeout):

        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()
        timeout = self._get_timeout_impl(timeout)

        self._bind(
            portal_name,
            state.name,
            state._encode_bind_msg(args))

        self.last_query = state.query
        self.statement = state

        return await self._new_waiter(timeout)

    async def execute(self, PreparedStatementState state,
                      str portal_name, int limit, return_extra,
                      timeout):

        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()
        timeout = self._get_timeout_impl(timeout)

        self._execute(
            portal_name,
            limit)

        self.last_query = state.query
        self.statement = state
        self.return_extra = return_extra
        self.queries_count += 1

        return await self._new_waiter(timeout)

    async def query(self, query, timeout):
        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()
        # query() needs to call _get_timeout instead of _get_timeout_impl
        # for consistent validation, as it is called differently from
        # prepare/bind/execute methods.
        timeout = self._get_timeout(timeout)

        self._simple_query(query)
        self.last_query = query
        self.queries_count += 1

        return await self._new_waiter(timeout)

    async def copy_out(self, copy_stmt, sink, timeout):
        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()

        timeout = self._get_timeout_impl(timeout)
        timer = Timer(timeout)

        # The copy operation is guarded by a single timeout
        # on the top level.
        waiter = self._new_waiter(timer.get_remaining_budget())

        self._copy_out(copy_stmt)

        try:
            while True:
                self.resume_reading()

                with timer:
                    buffer, done, status_msg = await waiter

                # buffer will be empty if CopyDone was received apart from
                # the last CopyData message.
                if buffer:
                    try:
                        with timer:
                            await asyncio.wait_for(
                                sink(buffer),
                                timeout=timer.get_remaining_budget(),
                                loop=self.loop)
                    except Exception as ex:
                        # Abort the COPY operation on any error in
                        # output sink.
                        self._request_cancel()
                        raise

                # done will be True upon receipt of CopyDone.
                if done:
                    break

                waiter = self._new_waiter(timer.get_remaining_budget())

        finally:
            self.resume_reading()

        return status_msg

    async def copy_in(self, copy_stmt, reader, data,
                      records, PreparedStatementState record_stmt, timeout):
        cdef:
            WriteBuffer wbuf
            ssize_t num_cols
            Codec codec

        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()

        timeout = self._get_timeout_impl(timeout)
        timer = Timer(timeout)

        waiter = self._new_waiter(timer.get_remaining_budget())

        # Initiate COPY IN.
        self._copy_in(copy_stmt)

        try:
            if record_stmt is not None:
                # copy_in_records in binary mode
                wbuf = WriteBuffer.new()
                # Signature
                wbuf.write_bytes(_COPY_SIGNATURE)
                # Flags field
                wbuf.write_int32(0)
                # No header extension
                wbuf.write_int32(0)

                record_stmt._ensure_rows_decoder()
                codecs = record_stmt.rows_codecs
                num_cols = len(codecs)
                settings = self.settings

                for codec in codecs:
                    if not codec.has_encoder():
                        raise RuntimeError(
                            'no encoder for OID {}'.format(codec.oid))

                for row in records:
                    # Tuple header
                    wbuf.write_int16(<int16_t>num_cols)
                    # Tuple data
                    for i in range(num_cols):
                        codec = <Codec>cpython.PyTuple_GET_ITEM(codecs, i)
                        codec.encode(settings, wbuf, row[i])

                    if wbuf.len() >= _COPY_BUFFER_SIZE:
                        with timer:
                            await self.writing_allowed.wait()
                        self._write_copy_data_msg(wbuf)
                        wbuf = WriteBuffer.new()

                # End of binary copy.
                wbuf.write_int16(-1)
                self._write_copy_data_msg(wbuf)

            elif reader is not None:
                try:
                    aiter = reader.__aiter__
                except AttributeError:
                    raise TypeError('reader is not an asynchronous iterable')
                else:
                    iterator = aiter()

                try:
                    while True:
                        # We rely on protocol flow control to moderate the
                        # rate of data messages.
                        with timer:
                            await self.writing_allowed.wait()
                        with timer:
                            chunk = await asyncio.wait_for(
                                iterator.__anext__(),
                                timeout=timer.get_remaining_budget(),
                                loop=self.loop)
                        self._write_copy_data_msg(chunk)
                except builtins.StopAsyncIteration:
                    pass
            else:
                # Buffer passed in directly.
                await self.writing_allowed.wait()
                self._write_copy_data_msg(data)

        except asyncio.TimeoutError:
            self._write_copy_fail_msg('TimeoutError')
            self._on_timeout(self.waiter)
            try:
                await waiter
            except TimeoutError:
                raise
            else:
                raise RuntimeError('TimoutError was not raised')

        except Exception as e:
            self._write_copy_fail_msg(str(e))
            self._request_cancel()
            raise

        self._write_copy_done_msg()

        status_msg = await waiter

        return status_msg

    async def close_statement(self, PreparedStatementState state, timeout):
        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._check_state()
        timeout = self._get_timeout_impl(timeout)

        if state.refs != 0:
            raise RuntimeError(
                'cannot close prepared statement; refs == {} != 0'.format(
                    state.refs))

        self._close(state.name, False)
        state.closed = True
        return await self._new_waiter(timeout)

    def is_closed(self):
        return self.closing

    def is_connected(self):
        return not self.closing and self.con_status == CONNECTION_OK

    def abort(self):
        if self.closing:
            return
        self.closing = True
        self._handle_waiter_on_connection_lost(None)
        self._terminate()
        self.transport.abort()

    async def close(self):
        if self.cancel_waiter is not None:
            await self.cancel_waiter
        if self.cancel_sent_waiter is not None:
            await self.cancel_sent_waiter
            self.cancel_sent_waiter = None

        self._handle_waiter_on_connection_lost(None)
        assert self.waiter is None

        if self.closing:
            return

        self._terminate()
        self.waiter = self.create_future()
        self.closing = True
        self.transport.abort()
        return await self.waiter

    def _request_cancel(self):
        self.cancel_waiter = self.create_future()
        self.cancel_sent_waiter = self.create_future()
        self.connection._cancel_current_command(self.cancel_sent_waiter)
        self._set_state(PROTOCOL_CANCELLED)

    def _on_timeout(self, fut):
        if self.waiter is not fut or fut.done() or \
                self.cancel_waiter is not None or \
                self.timeout_handle is None:
            return
        self._request_cancel()
        self.waiter.set_exception(asyncio.TimeoutError())

    def _on_waiter_completed(self, fut):
        if fut is not self.waiter or self.cancel_waiter is not None:
            return
        if fut.cancelled():
            if self.timeout_handle:
                self.timeout_handle.cancel()
                self.timeout_handle = None
            self._request_cancel()

    def _create_future_fallback(self):
        return asyncio.Future(loop=self.loop)

    cdef _handle_waiter_on_connection_lost(self, cause):
        if self.waiter is not None and not self.waiter.done():
            exc = apg_exc.ConnectionDoesNotExistError(
                'connection was closed in the middle of '
                'operation')
            if cause is not None:
                exc.__cause__ = cause
            self.waiter.set_exception(exc)
        self.waiter = None

    cdef _set_server_parameter(self, name, val):
        self.settings.add_setting(name, val)

    def _get_timeout(self, timeout):
        if timeout is not None:
            try:
                if type(timeout) is bool:
                    raise ValueError
                timeout = float(timeout)
            except ValueError:
                raise ValueError(
                    'invalid timeout value: expected non-negative float '
                    '(got {!r})'.format(timeout)) from None

        return self._get_timeout_impl(timeout)

    cdef inline _get_timeout_impl(self, timeout):
        if timeout is None:
            timeout = self.connection._config.command_timeout
        elif timeout is NO_TIMEOUT:
            timeout = None
        else:
            timeout = float(timeout)

        if timeout is not None and timeout <= 0:
            raise asyncio.TimeoutError()
        return timeout

    cdef _check_state(self):
        if self.cancel_waiter is not None:
            raise apg_exc.InterfaceError(
                'cannot perform operation: another operation is cancelling')
        if self.closing:
            raise apg_exc.InterfaceError(
                'cannot perform operation: connection is closed')
        if self.waiter is not None or self.timeout_handle is not None:
            raise apg_exc.InterfaceError(
                'cannot perform operation: another operation is in progress')

    cdef _new_waiter(self, timeout):
        if self.waiter is not None:
            raise apg_exc.InterfaceError(
                'cannot perform operation: another operation is in progress')
        self.waiter = self.create_future()
        if timeout is not None:
            self.timeout_handle = self.connection._loop.call_later(
                timeout, self.timeout_callback, self.waiter)
        self.waiter.add_done_callback(self.completed_callback)
        return self.waiter

    cdef _on_result__connect(self, object waiter):
        waiter.set_result(True)

    cdef _on_result__prepare(self, object waiter):
        if ASYNCPG_DEBUG:
            if self.statement is None:
                raise RuntimeError(
                    '_on_result__prepare: statement is None')

        if self.result_param_desc is not None:
            self.statement._set_args_desc(self.result_param_desc)
        if self.result_row_desc is not None:
            self.statement._set_row_desc(self.result_row_desc)
        waiter.set_result(self.statement)

    cdef _on_result__bind_and_exec(self, object waiter):
        if self.return_extra:
            waiter.set_result((
                self.result,
                self.result_status_msg,
                self.result_execute_completed))
        else:
            waiter.set_result(self.result)

    cdef _on_result__bind(self, object waiter):
        waiter.set_result(self.result)

    cdef _on_result__close_stmt_or_portal(self, object waiter):
        waiter.set_result(self.result)

    cdef _on_result__simple_query(self, object waiter):
        waiter.set_result(self.result_status_msg.decode(self.encoding))

    cdef _on_result__copy_out(self, object waiter):
        cdef bint copy_done = self.state == PROTOCOL_COPY_OUT_DONE
        if copy_done:
            status_msg = self.result_status_msg.decode(self.encoding)
        else:
            status_msg = None

        # We need to put some backpressure on Postgres
        # here in case the sink is slow to process the output.
        self.pause_reading()

        waiter.set_result((self.result, copy_done, status_msg))

    cdef _on_result__copy_in(self, object waiter):
        status_msg = self.result_status_msg.decode(self.encoding)
        waiter.set_result(status_msg)

    cdef _decode_row(self, const char* buf, ssize_t buf_len):
        if ASYNCPG_DEBUG:
            if self.statement is None:
                raise RuntimeError(
                    '_decode_row: statement is None')

        return self.statement._decode_row(buf, buf_len)

    cdef _dispatch_result(self):
        waiter = self.waiter
        self.waiter = None

        if ASYNCPG_DEBUG:
            if waiter is None:
                raise RuntimeError('_on_result: waiter is None')

        if waiter.cancelled():
            return

        if waiter.done():
            raise RuntimeError('_on_result: waiter is done')

        if self.result_type == RESULT_FAILED:
            if isinstance(self.result, dict):
                exc = apg_exc_base.PostgresMessage.new(
                    self.result, query=self.last_query)
            else:
                exc = self.result
            waiter.set_exception(exc)
            return

        try:
            if self.state == PROTOCOL_AUTH:
                self._on_result__connect(waiter)

            elif self.state == PROTOCOL_PREPARE:
                self._on_result__prepare(waiter)

            elif self.state == PROTOCOL_BIND_EXECUTE:
                self._on_result__bind_and_exec(waiter)

            elif self.state == PROTOCOL_BIND_EXECUTE_MANY:
                self._on_result__bind_and_exec(waiter)

            elif self.state == PROTOCOL_EXECUTE:
                self._on_result__bind_and_exec(waiter)

            elif self.state == PROTOCOL_BIND:
                self._on_result__bind(waiter)

            elif self.state == PROTOCOL_CLOSE_STMT_PORTAL:
                self._on_result__close_stmt_or_portal(waiter)

            elif self.state == PROTOCOL_SIMPLE_QUERY:
                self._on_result__simple_query(waiter)

            elif (self.state == PROTOCOL_COPY_OUT_DATA or
                    self.state == PROTOCOL_COPY_OUT_DONE):
                self._on_result__copy_out(waiter)

            elif self.state == PROTOCOL_COPY_IN_DATA:
                self._on_result__copy_in(waiter)

            else:
                raise RuntimeError(
                    'got result for unknown protocol state {}'.
                    format(self.state))

        except Exception as exc:
            waiter.set_exception(exc)

    cdef _on_result(self):
        if self.timeout_handle is not None:
            self.timeout_handle.cancel()
            self.timeout_handle = None

        if self.cancel_waiter is not None:
            # We have received the result of a cancelled operation.
            # Simply ignore the result.
            self.cancel_waiter.set_result(None)
            self.cancel_waiter = None
            self.waiter = None
            return

        try:
            self._dispatch_result()
        finally:
            self.statement = None
            self.last_query = None
            self.return_extra = False

    cdef _on_notification(self, pid, channel, payload):
        self.connection._notify(pid, channel, payload)

    cdef _on_connection_lost(self, exc):
        if self.closing:
            # The connection was lost because
            # Protocol.close() was called
            if self.waiter is not None and not self.waiter.done():
                if exc is None:
                    self.waiter.set_result(None)
                else:
                    self.waiter.set_exception(exc)
            self.waiter = None
        else:
            # The connection was lost because it was
            # terminated or due to another error;
            # Throw an error in any awaiting waiter.
            self.closing = True
            self._handle_waiter_on_connection_lost(exc)

    def pause_writing(self):
        self.writing_allowed.clear()

    def resume_writing(self):
        self.writing_allowed.set()


class Timer:
    def __init__(self, budget):
        self._budget = budget
        self._started = 0

    def __enter__(self):
        if self._budget is not None:
            self._started = time.monotonic()

    def __exit__(self, et, e, tb):
        if self._budget is not None:
            self._budget -= time.monotonic() - self._started

    def get_remaining_budget(self):
        return self._budget


class Protocol(BaseProtocol, asyncio.Protocol):
    pass


def _create_record(object mapping, tuple elems):
    # Exposed only for testing purposes.

    cdef:
        object rec
        int32_t i

    if mapping is None:
        desc = record.ApgRecordDesc_New({}, ())
    else:
        desc = record.ApgRecordDesc_New(
            mapping, tuple(mapping) if mapping else ())

    rec = record.ApgRecord_New(desc, len(elems))
    for i in range(len(elems)):
        elem = elems[i]
        cpython.Py_INCREF(elem)
        record.ApgRecord_SET_ITEM(rec, i, elem)
    return rec


Record = <object>record.ApgRecord_InitTypes()

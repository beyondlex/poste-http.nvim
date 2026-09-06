"""Poste gRPC test server — echo service with server reflection.

Unary Echo (metadata echo-back), server-streaming EchoStream, and a Fail
RPC that returns a controllable gRPC status code for testing Poste's
status mapping. Reflection is enabled so grpcurl needs no proto files.
"""

import os
from concurrent import futures

import grpc

import echo_pb2
import echo_pb2_grpc
from grpc_reflection.v1alpha import reflection

STATUS_NAMES = {
    "OK": grpc.StatusCode.OK,
    "INVALID_ARGUMENT": grpc.StatusCode.INVALID_ARGUMENT,
    "DEADLINE_EXCEEDED": grpc.StatusCode.DEADLINE_EXCEEDED,
    "NOT_FOUND": grpc.StatusCode.NOT_FOUND,
    "ALREADY_EXISTS": grpc.StatusCode.ALREADY_EXISTS,
    "PERMISSION_DENIED": grpc.StatusCode.PERMISSION_DENIED,
    "RESOURCE_EXHAUSTED": grpc.StatusCode.RESOURCE_EXHAUSTED,
    "FAILED_PRECONDITION": grpc.StatusCode.FAILED_PRECONDITION,
    "UNIMPLEMENTED": grpc.StatusCode.UNIMPLEMENTED,
    "INTERNAL": grpc.StatusCode.INTERNAL,
    "UNAVAILABLE": grpc.StatusCode.UNAVAILABLE,
    "UNAUTHENTICATED": grpc.StatusCode.UNAUTHENTICATED,
}


class EchoService(echo_pb2_grpc.EchoServiceServicer):
    def Echo(self, request, context):
        resp = echo_pb2.EchoResponse(message=request.message, seq=0)
        for key, value in context.invocation_metadata():
            resp.metadata[key] = value
        return resp

    def EchoStream(self, request, context):
        repeat = request.repeat if request.repeat > 0 else 3
        for seq in range(repeat):
            yield echo_pb2.EchoResponse(message=f"{request.message} #{seq}", seq=seq)

    def Fail(self, request, context):
        code = STATUS_NAMES.get(request.code.upper(), grpc.StatusCode.UNKNOWN)
        context.set_code(code)
        context.set_details(request.message or f"failed with {request.code}")
        return echo_pb2.EchoResponse()


class OrderService(echo_pb2_grpc.OrderServiceServicer):
    def PreviewOrder(self, request, context):
        total = sum(item.quantity * item.unit_price for item in request.items)
        return echo_pb2.OrderPreview(
            preview_id=f"prev-{request.customer_id}",
            total=total,
            currency="USD",
        )


def serve():
    port = os.environ.get("POSTE_GRPC_PORT", "8891")
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    echo_pb2_grpc.add_EchoServiceServicer_to_server(EchoService(), server)
    echo_pb2_grpc.add_OrderServiceServicer_to_server(OrderService(), server)
    service_names = (
        echo_pb2.DESCRIPTOR.services_by_name["EchoService"].full_name,
        echo_pb2.DESCRIPTOR.services_by_name["OrderService"].full_name,
        reflection.SERVICE_NAME,
    )
    reflection.enable_server_reflection(service_names, server)
    server.add_insecure_port(f"[::]:{port}")
    server.start()
    print(f"poste-grpc-echo listening on :{port}", flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    serve()

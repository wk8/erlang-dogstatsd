#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "erl_nif.h"

#define BUFFER_SIZE 2048
#define MAX_IP_SIZE 64

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_send_failed;
static ERL_NIF_TERM atom_init_failed;
static ERL_NIF_TERM atom_must_init_first;

// there's one buffer per process
static ErlNifResourceType* buffer_resource;

typedef enum { INIT_NOT_DONE_YET, INIT_SUCCESSFUL, INIT_FAILED } init_state;
static init_state init_status = INIT_NOT_DONE_YET;

static char server_ip[MAX_IP_SIZE];
static int server_port;
static struct sockaddr_in edogstatsd_server;
static int socket_fd = -1;
static int sockaddr_in_size = sizeof(struct sockaddr_in);

// expects the server's IP (as a string) as first argument, and the port as
// second argument (as an int)
static ERL_NIF_TERM edogstatsd_udp_init(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  // process arguments
  if (enif_get_string(env, argv[0], server_ip, MAX_IP_SIZE, ERL_NIF_LATIN1) <= 0
      || !enif_get_int(env, argv[1], &server_port)) {
    return enif_make_badarg(env);
  }
  // inet_aton doesn't like "localhost"...
  if (!strcmp(server_ip, "localhost")) {
    memcpy(server_ip, "127.0.0.1", 10);
  }

  init_status = INIT_FAILED;

  // close the socket if relevant
  if (socket_fd != -1) {
    close(socket_fd);
  }

  // open the socket
  socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (socket_fd == -1) {
    return enif_make_tuple2(env, atom_error, enif_make_atom(env, "could_not_create_socket"));
  }

  // populate the sockaddr_in
  memset(&edogstatsd_server, 0, sockaddr_in_size);
  edogstatsd_server.sin_family = AF_INET;
  edogstatsd_server.sin_port = htons(server_port);
  if (!inet_aton(server_ip, &edogstatsd_server.sin_addr)) {
    return enif_make_tuple2(env, atom_error, enif_make_atom(env, "inet_aton_failed"));
  }

  init_status = INIT_SUCCESSFUL;
  return atom_ok;
}

static ERL_NIF_TERM edogstatsd_new_buffer(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  ErlNifBinary* buffer = enif_alloc_resource(buffer_resource, sizeof(ErlNifBinary));

  if (!enif_alloc_binary(BUFFER_SIZE, buffer)) {
    return atom_error;
  }

  // wrap it in a resource
  ERL_NIF_TERM resource = enif_make_resource(env, buffer);
  enif_release_resource(buffer);
  return enif_make_tuple2(env, atom_ok, resource);
}

// 1st agument should be a buffer resource,
// 2nd one an IO list
static ERL_NIF_TERM edogstatsd_udp_send(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  ErlNifBinary* buffer;

  switch(init_status) {
    case INIT_SUCCESSFUL:
      if (!enif_get_resource(env, argv[0], buffer_resource, (void **)&buffer)
         || !enif_inspect_iolist_as_binary(env, argv[1], buffer)) {
        return enif_make_badarg(env);
      }

      int sent_count = sendto(socket_fd, buffer->data, buffer->size, 0,
                              (struct sockaddr*) &edogstatsd_server, sockaddr_in_size);
      if (sent_count == buffer->size) {
        return atom_ok;
      } else {
        return enif_make_tuple4(env, atom_error, atom_send_failed, sent_count, buffer->size);
      };
    case INIT_FAILED:
      return enif_make_tuple2(env, atom_error, atom_init_failed);
    case INIT_NOT_DONE_YET:
    default:
      return enif_make_tuple2(env, atom_error, atom_must_init_first);
  }
}

void free_buffer(ErlNifEnv* env, void* obj)
{
  ErlNifBinary* buffer = (ErlNifBinary*) obj;

  if (buffer) {
    enif_release_binary(buffer);
  }
}

static int edogstatsd_udp_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
  atom_ok = enif_make_atom(env, "ok");
  atom_error = enif_make_atom(env, "error");
  atom_send_failed = enif_make_atom(env, "send_failed");
  atom_init_failed = enif_make_atom(env, "init_failed");
  atom_must_init_first = enif_make_atom(env, "must_init_first");

  // init the resource
  ErlNifResourceType* resource = enif_open_resource_type(env, NULL, "edogstatsd_udp", free_buffer,
                                                         ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
                                                         NULL);

  if(resource) {
    buffer_resource = resource;
    return 0;
  } else {
    return 1;
  }
}


static ErlNifFunc edogstatsd_udp_nif_funcs[] = {
  {"init",       2, edogstatsd_udp_init},
  {"new_buffer", 0, edogstatsd_new_buffer},
  {"send",       2, edogstatsd_udp_send}
};

ERL_NIF_INIT(edogstatsd_udp, edogstatsd_udp_nif_funcs, edogstatsd_udp_load, NULL, NULL, NULL)

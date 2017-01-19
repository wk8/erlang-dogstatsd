#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "erl_nif.h"

#define BUFFER_SIZE 4096
#define MAX_IP_SIZE 64
#define MAX_IDLE_POOL_SIZE 10

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_send_failed;
static ERL_NIF_TERM atom_init_failed;
static ERL_NIF_TERM atom_must_init_first;

// we have a pool of socket and buffers that all processes share
typedef struct worker_space_t {
  int socket;
  ErlNifBinary* buffer;
  int version;
  // that's only ever non-NULL when sitting idle in the queue
  struct worker_space_t* next;
}

static worker_space_t* pool = NULL;
static int current_pool_size = 0;
// bumped at each init
static int current_pool_version = 0;

// checking a socket and a buffer in and out of the pool needs to be
// synchronized
ErlNifRWLock* pool_lock = NULL;

typedef enum { INIT_NOT_DONE_YET, INIT_SUCCESSFUL, INIT_FAILED } init_state;
static init_state init_status = INIT_NOT_DONE_YET;

static char server_ip[MAX_IP_SIZE];
static int server_port;
static struct sockaddr_in edogstatsd_server;
static int sockaddr_in_size = sizeof(struct sockaddr_in);

// expects the server's IP (as a string) as first argument, and the port as
// second argument (as an int)
static ERL_NIF_TERM edogstatsd_udp_init(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  enif_rwlock_rwlock(pool_lock);

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

  // need to bump the current pool version
  current_pool_version++;

  // populate the sockaddr_in
  memset(&edogstatsd_server, 0, sockaddr_in_size);
  edogstatsd_server.sin_family = AF_INET;
  edogstatsd_server.sin_port = htons(server_port);
  if (!inet_aton(server_ip, &edogstatsd_server.sin_addr)) {
    return enif_make_tuple2(env, atom_error, enif_make_atom(env, "inet_aton_failed"));
  }

  init_status = INIT_SUCCESSFUL;

  enif_rwlock_rwunlock(pool_lock);

  return atom_ok;
}

worker_space_t* alloc_worker_space() {
  worker_space_t* worker_space = (worker_space_t*) calloc(1, sizeof(worker_space_t)); // TODO wkpo calloc header needed?

  if (!worker_space) {
    return NULL;
  }

  enif_rwlock_rwlock(pool_lock);

  worker_space->socket = -1;
  worker_space->buffer = NULL;
  worker_space->version = current_pool_version;
  worker_space->next = NULL;

  // open the socket
  worker_space->socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (worker_space->socket == -1) {
    goto cleanup_failed_alloc_worker_space;
  }

  // allocate the buffer
  if (!enif_alloc_binary(BUFFER_SIZE, worker_space->buffer)) {
    goto cleanup_failed_alloc_worker_space;
  }

  enif_rwlock_rwunlock(pool_lock);

  return worker_space;

cleanup_failed_alloc_worker_space:
  free(worker_space);
  enif_rwlock_rwunlock(pool_lock);
  return NULL;
}

void free_worker_space(worker_space_t* worker_space)
{
  if (worker_space) {
    if (worker_space->buffer) {
      enif_release_binary(buffer);
    }

    if (worker_space->socket >= 0) {
      close(worker_space->socket);
    }

    free(worker_space);
  }
}

worker_space_t* check_out_worker_space()
{
  worker_space_t* worker_space;

  // try to find one sitting in the queue
  worker_space = pool;
  while (worker_space) {
    if (worker_space->version == current_pool_version) {
      // we're done!
      // TODO wkpo from here
      pool = worker_space_t
    }
  }
}

void check_in_worker_space(worker_space_t* worker_space)
{
  
}

// the only argument should be a list of IO lists
static ERL_NIF_TERM edogstatsd_udp_send(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  ErlNifBinary* buffer;

  switch(init_status) {
    case INIT_SUCCESSFUL:
      if (!enif_get_resource(env, argv[0], buffer_resource, (void **)&buffer)
         || !enif_inspect_iolist_as_binary(env, argv[1], buffer)) {
        return enif_make_badarg(env);
      }

      enif_rwlock_rwlock(pool_lock);
      int sent_count = sendto(socket_fd, buffer->data, buffer->size, 0,
                              (struct sockaddr*) &edogstatsd_server, sockaddr_in_size);
      enif_rwlock_rwunlock(pool_lock);
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



// TODO wkpo oldies

  // close the socket if relevant
  if (socket_fd != -1) {
    close(socket_fd);
  }







static ERL_NIF_TERM edogstatsd_new_buffer(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  enif_rwlock_rwlock(buffers_lock);

  ErlNifBinary* buffer = enif_alloc_resource(buffer_resource, sizeof(ErlNifBinary));

  if (!enif_alloc_binary(BUFFER_SIZE, buffer)) {
    enif_rwlock_rwunlock(buffers_lock);
    return atom_error;
  }

  // wrap it in a resource
  ERL_NIF_TERM resource = enif_make_resource(env, buffer);
  enif_release_resource(buffer);
  enif_rwlock_rwunlock(buffers_lock);
  return enif_make_tuple2(env, atom_ok, resource);
}

static int edogstatsd_udp_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
  atom_ok = enif_make_atom(env, "ok");
  atom_error = enif_make_atom(env, "error");
  atom_send_failed = enif_make_atom(env, "send_failed");
  atom_init_failed = enif_make_atom(env, "init_failed");
  atom_must_init_first = enif_make_atom(env, "must_init_first");

  // init the resource
  buffer_resource = enif_open_resource_type(env, NULL, "edogstatsd_udp", free_buffer,
                                            ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
                                            NULL);

  // init the lock
  buffers_lock = enif_rwlock_create("edogstatsd_udp_buffers_lock");

  return buffer_resource && buffers_lock ? 0 : 1;
}

static ErlNifFunc edogstatsd_udp_nif_funcs[] = {
  {"init", 2, edogstatsd_udp_init},
  {"send", 1, edogstatsd_udp_send}
  // TODO wkpo get current size, get created ever count?
};

ERL_NIF_INIT(edogstatsd_udp, edogstatsd_udp_nif_funcs, edogstatsd_udp_load, NULL, NULL, NULL)

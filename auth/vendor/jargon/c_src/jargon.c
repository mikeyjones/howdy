#include "erl_nif.h"

#include "argon2.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARGON2_VERSION ARGON2_VERSION_NUMBER
#define JARGON_IS_VALID_TYPE(v) (v <= Argon2_id)
#define JARGON_ERROR_TUPLE(env, error)                                         \
  enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_int(env, error))

static ERL_NIF_TERM argon2_hash_nif(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  if (argc != 7) {
    return enif_make_badarg(env);
  }

  uint32_t t_cost, m_cost, parallelism, hash_len, algorithm;
  ErlNifBinary password, salt;
  char *raw_hash = NULL;
  char *encoded_hash = NULL;
  size_t encoded_hash_len = 0;

  if (!enif_inspect_binary(env, argv[0], &password) ||
      !enif_inspect_binary(env, argv[1], &salt) ||
      !enif_get_uint(env, argv[2], &algorithm) ||
      !enif_get_uint(env, argv[3], &t_cost) ||
      !enif_get_uint(env, argv[4], &m_cost) ||
      !enif_get_uint(env, argv[5], &parallelism) ||
      !enif_get_uint(env, argv[6], &hash_len) ||
      !JARGON_IS_VALID_TYPE(algorithm)) {
    return enif_make_badarg(env);
  }

  raw_hash = malloc(hash_len);
  if (raw_hash == NULL) {
    return JARGON_ERROR_TUPLE(env, ARGON2_MEMORY_ALLOCATION_ERROR);
  }

  encoded_hash_len =
      argon2_encodedlen(t_cost, m_cost, parallelism, (uint32_t)salt.size,
                        hash_len, (argon2_type)algorithm);

  encoded_hash = malloc(encoded_hash_len);
  if (encoded_hash == NULL) {
    free(raw_hash);
    return JARGON_ERROR_TUPLE(env, ARGON2_MEMORY_ALLOCATION_ERROR);
  }

  ERL_NIF_TERM result_nif;

  uint32_t result;

  result =
      argon2_hash((uint32_t)t_cost, m_cost, parallelism, password.data,
                  (size_t)password.size, salt.data, (size_t)salt.size, raw_hash,
                  (size_t)hash_len, encoded_hash, encoded_hash_len,
                  (argon2_type)algorithm, ARGON2_VERSION);

  if (result != ARGON2_OK) {
    free(raw_hash);
    free(encoded_hash);
    return JARGON_ERROR_TUPLE(env, result);
  }

  ERL_NIF_TERM hash_nif_term;
  unsigned char *hash_nif_term_data =
      enif_make_new_binary(env, hash_len, &hash_nif_term);
  if (!hash_nif_term_data) {
    free(raw_hash);
    free(encoded_hash);
    return enif_make_badarg(env);
  }
  memcpy(hash_nif_term_data, raw_hash, hash_len);

  encoded_hash_len--; // remove null terminator
  ERL_NIF_TERM encoded_hash_term;
  unsigned char *encoded_hash_term_data =
      enif_make_new_binary(env, encoded_hash_len, &encoded_hash_term);
  if (!encoded_hash_term_data) {
    free(raw_hash);
    free(encoded_hash);
    return enif_make_badarg(env);
  }
  memcpy(encoded_hash_term_data, encoded_hash, encoded_hash_len);

  result_nif = enif_make_tuple3(env, enif_make_atom(env, "ok"), hash_nif_term,
                                encoded_hash_term);

  if (raw_hash) {
    free(raw_hash);
  }
  if (encoded_hash) {
    free(encoded_hash);
  }

  return result_nif;
}

static ERL_NIF_TERM argon2_verify_nif(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  ErlNifBinary encoded_hash, pwd_param;
  unsigned int type_param;
  int result;

  if (argc != 3 || !enif_inspect_binary(env, argv[0], &encoded_hash) ||
      !enif_inspect_binary(env, argv[1], &pwd_param) ||
      !enif_get_uint(env, argv[2], &type_param) ||
      !JARGON_IS_VALID_TYPE(type_param)) {
    return enif_make_badarg(env);
  }

  char *c_str = (char *)enif_alloc(encoded_hash.size + 1);
  if (c_str == NULL) {
    return enif_make_badarg(env); // Allocation failed
  }

  memcpy(c_str, encoded_hash.data, encoded_hash.size);
  c_str[encoded_hash.size] = '\0';

  result = argon2_verify(c_str, pwd_param.data, (size_t)pwd_param.size,
                         (argon2_type)type_param);
  enif_free(c_str);

  if (result == ARGON2_OK) {
    return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                            enif_make_atom(env, "true"));
  }
  if (result == ARGON2_VERIFY_MISMATCH) {
    return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                            enif_make_atom(env, "false"));
  }

  return JARGON_ERROR_TUPLE(env, result);
}

static ErlNifFunc nif_funcs[] = {
    {"hash_nif", 7, argon2_hash_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"verify_nif", 3, argon2_verify_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(jargon, nif_funcs, NULL, NULL, NULL, NULL)

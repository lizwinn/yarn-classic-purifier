#include <node_api.h>

static napi_value init(napi_env env, napi_value exports) {
  napi_value answer;
  if (napi_create_int32(env, 42, &answer) != napi_ok) return NULL;
  if (napi_set_named_property(env, exports, "answer", answer) != napi_ok) return NULL;
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)

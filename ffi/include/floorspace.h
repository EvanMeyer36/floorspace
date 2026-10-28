// C interface to the Floorspace engine (see ffi/src/lib.rs).
//
// Every request is a method name plus a JSON object of arguments; every reply is a JSON object,
// either {"ok": <value>} or {"error": "<message>"}. Free each reply with floorspace_free.
// Calls that scan or remove block until done, so call them off the main thread. All calls share
// one engine session: things are referred to by ID from its latest results.
#ifndef FLOORSPACE_H
#define FLOORSPACE_H

char *floorspace_call(const char *method, const char *args_json);
void floorspace_free(char *reply);

#endif

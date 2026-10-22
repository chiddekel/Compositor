#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>

static inline void compositorXMLFree(void *buffer) { xmlFree(buffer); }

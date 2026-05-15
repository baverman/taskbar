#include <poll.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <time.h>
#include <cairo/cairo.h>

typedef struct _PangoLayout PangoLayout;
typedef struct _PangoFontDescription PangoFontDescription;

enum {
    PANGO_SCALE = 1024,
    PANGO_ALIGN_LEFT = 0,
    PANGO_ALIGN_CENTER = 1,
    PANGO_ALIGN_RIGHT = 2,
    PANGO_ELLIPSIZE_NONE = 0,
    PANGO_ELLIPSIZE_END = 3,
};

void g_object_unref(void *object);
PangoLayout *pango_cairo_create_layout(cairo_t *cr);
void pango_cairo_show_layout(cairo_t *cr, PangoLayout *layout);
PangoFontDescription *pango_font_description_from_string(const char *str);
void pango_font_description_free(PangoFontDescription *desc);
void pango_layout_get_pixel_size(PangoLayout *layout, int *width, int *height);
void pango_layout_set_alignment(PangoLayout *layout, int alignment);
void pango_layout_set_ellipsize(PangoLayout *layout, int ellipsize);
void pango_layout_set_font_description(PangoLayout *layout, PangoFontDescription *desc);
void pango_layout_set_text(PangoLayout *layout, const char *text, int length);
void pango_layout_set_width(PangoLayout *layout, int width);

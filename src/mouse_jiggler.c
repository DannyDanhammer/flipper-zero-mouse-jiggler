#include <furi.h>
#include <furi_hal.h>
#include <furi_hal_usb.h>
#include <furi_hal_usb_hid.h>

#include <gui/gui.h>
#include <gui/view_port.h>
#include <gui/canvas.h>
#include <input/input.h>

#ifndef JIGGLE_PIXELS
#define JIGGLE_PIXELS 40
#endif

#ifndef JIGGLE_DELAY_MS
#define JIGGLE_DELAY_MS 500
#endif

typedef struct {
    FuriMessageQueue* queue;
    bool usb_switch_ok;
    bool connected;
    bool last_report_ok;
} MouseJigglerApp;

static void mouse_jiggler_draw(Canvas* canvas, void* context) {
    MouseJigglerApp* app = context;

    canvas_clear(canvas);
    canvas_set_font(canvas, FontPrimary);
    canvas_draw_str(canvas, 18, 13, "Mouse Jiggler");

    canvas_set_font(canvas, FontSecondary);

    if(!app->usb_switch_ok) {
        canvas_draw_str(canvas, 12, 30, "USB HID switch FAILED");
    } else if(app->connected) {
        canvas_draw_str(canvas, 17, 30, "USB HID connected");
        if(app->last_report_ok) {
            canvas_draw_str(canvas, 16, 44, "Mouse report: OK");
        } else {
            canvas_draw_str(canvas, 12, 44, "Mouse report: WAIT");
        }
    } else {
        canvas_draw_str(canvas, 14, 30, "Waiting for Windows");
        canvas_draw_str(canvas, 21, 44, "to attach HID...");
    }

    canvas_draw_str(canvas, 24, 60, "BACK = STOP");
}

static void mouse_jiggler_input(InputEvent* event, void* context) {
    MouseJigglerApp* app = context;

    if(
        (event->type == InputTypeShort || event->type == InputTypePress) &&
        event->key == InputKeyBack) {
        furi_message_queue_put(app->queue, event, 0);
    }
}

int32_t mouse_jiggler_app(void* p) {
    UNUSED(p);

    MouseJigglerApp app = {
        .queue = furi_message_queue_alloc(8, sizeof(InputEvent)),
        .usb_switch_ok = false,
        .connected = false,
        .last_report_ok = false,
    };

    ViewPort* view_port = view_port_alloc();
    view_port_draw_callback_set(view_port, mouse_jiggler_draw, &app);
    view_port_input_callback_set(view_port, mouse_jiggler_input, &app);

    Gui* gui = furi_record_open(RECORD_GUI);
    gui_add_view_port(gui, view_port, GuiLayerFullscreen);

    const FuriHalUsbInterface* previous_usb = furi_hal_usb_get_config();

    app.usb_switch_ok = furi_hal_usb_set_config(&usb_hid, NULL);
    view_port_update(view_port);

    if(app.usb_switch_ok) {
        for(uint8_t i = 0; i < 30; i++) {
            InputEvent event;

            if(furi_message_queue_get(app.queue, &event, 100) == FuriStatusOk) {
                if(event.key == InputKeyBack) {
                    goto cleanup;
                }
            }

            app.connected = furi_hal_hid_is_connected();
            view_port_update(view_port);

            if(app.connected) {
                break;
            }
        }
    }

    bool move_right = true;

    while(true) {
        InputEvent event;

        if(
            furi_message_queue_get(
                app.queue,
                &event,
                JIGGLE_DELAY_MS) == FuriStatusOk) {

            if(event.key == InputKeyBack) {
                break;
            }
        }

        bool now_connected = furi_hal_hid_is_connected();

        if(now_connected != app.connected) {
            app.connected = now_connected;
            view_port_update(view_port);
        }

        if(app.usb_switch_ok && app.connected) {
            bool sent = false;

            if(move_right) {
                sent = furi_hal_hid_mouse_move(JIGGLE_PIXELS, 0);
            } else {
                sent = furi_hal_hid_mouse_move(-JIGGLE_PIXELS, 0);
            }

            app.last_report_ok = sent;
            view_port_update(view_port);
            move_right = !move_right;
        }
    }

cleanup:
    if(previous_usb) {
        furi_hal_usb_set_config((FuriHalUsbInterface*)previous_usb, NULL);
    }

    gui_remove_view_port(gui, view_port);
    view_port_free(view_port);
    furi_record_close(RECORD_GUI);
    furi_message_queue_free(app.queue);

    return 0;
}

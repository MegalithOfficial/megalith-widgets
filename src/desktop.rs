//! Desktop placement and the shared placement action used by the GNOME extension.

#[cfg(feature = "layer-shell")]
use crate::prefs::Corner;
use crate::prefs::Settings;
use gtk::prelude::*;
use gtk::{gio, glib};

#[cfg(feature = "layer-shell")]
fn supports_layer_shell(window: &gtk::ApplicationWindow) -> bool {
    gtk::prelude::WidgetExt::display(window).type_().name() == "GdkWaylandDisplay"
        && gtk4_layer_shell::is_supported()
}

pub fn placement_state(settings: &Settings) -> glib::Variant {
    (
        settings.corner.as_str(),
        settings.custom_x,
        settings.custom_y,
    )
        .to_variant()
}

pub fn sync_position(window: &gtk::ApplicationWindow, settings: &Settings) {
    if let Some(action) = window
        .application()
        .and_then(|app| app.lookup_action("placement"))
        .and_then(|action| action.downcast::<gio::SimpleAction>().ok())
    {
        let state = placement_state(settings);
        if action.state().as_ref() != Some(&state) {
            action.set_state(&state);
        }
    }
    #[cfg(feature = "layer-shell")]
    {
        use gtk4_layer_shell::LayerShell;
        if window.is_layer_window() {
            position_layer(window, settings);
        }
    }
}

#[cfg_attr(not(feature = "layer-shell"), allow(unused_variables))]
pub fn place(window: &gtk::ApplicationWindow, settings: &Settings) {
    #[cfg(feature = "layer-shell")]
    if supports_layer_shell(window) {
        use gtk4_layer_shell::{KeyboardMode, Layer, LayerShell};
        window.init_layer_shell();
        window.set_namespace(Some("megalith-widgets"));
        window.set_layer(Layer::Bottom);
        window.set_keyboard_mode(KeyboardMode::OnDemand);
        position_layer(window, settings);
    }
}

#[cfg(feature = "layer-shell")]
fn position_layer(window: &gtk::ApplicationWindow, settings: &Settings) {
    use gtk4_layer_shell::{Edge, LayerShell};
    let bottom = matches!(settings.corner, Corner::BottomLeft | Corner::BottomRight);
    let right = matches!(settings.corner, Corner::TopRight | Corner::BottomRight);
    for (edge, anchor) in [
        (Edge::Top, !bottom),
        (Edge::Bottom, bottom),
        (Edge::Left, !right),
        (Edge::Right, right),
    ] {
        window.set_anchor(edge, anchor);
        window.set_margin(edge, 0);
    }
    let (x, y) = if settings.corner == Corner::Custom {
        (settings.custom_x.max(0), settings.custom_y.max(0))
    } else {
        (10, 10)
    };
    window.set_margin(if right { Edge::Right } else { Edge::Left }, x);
    window.set_margin(if bottom { Edge::Bottom } else { Edge::Top }, y);
}

#[cfg_attr(not(feature = "layer-shell"), allow(unused_variables))]
pub fn attach_drag(window: &gtk::ApplicationWindow, handle: &gtk::WindowHandle) {
    #[cfg(feature = "layer-shell")]
    if supports_layer_shell(window) {
        use gtk4_layer_shell::{Edge, LayerShell};
        use std::cell::Cell;
        use std::rc::Rc;

        let gesture = gtk::GestureDrag::builder()
            .button(1)
            .propagation_phase(gtk::PropagationPhase::Capture)
            .build();
        let moved = Rc::new(Cell::new(false));
        let origin = Rc::new(Cell::new((0, 0)));
        gesture.connect_drag_begin({
            let window = window.downgrade();
            let moved = moved.clone();
            let origin = origin.clone();
            move |gesture, _, _| {
                let Some(window) = window.upgrade() else {
                    return;
                };
                let Some(monitor) = window.surface().and_then(|surface| {
                    gtk::prelude::WidgetExt::display(&window).monitor_at_surface(&surface)
                }) else {
                    return;
                };
                let bounds = monitor.geometry();
                let x = if window.is_anchor(Edge::Right) {
                    bounds.width() - window.width() - window.margin(Edge::Right)
                } else {
                    window.margin(Edge::Left)
                };
                let y = if window.is_anchor(Edge::Bottom) {
                    bounds.height() - window.height() - window.margin(Edge::Bottom)
                } else {
                    window.margin(Edge::Top)
                };
                moved.set(false);
                origin.set((x, y));
                gesture.set_state(gtk::EventSequenceState::Claimed);
                position_layer(
                    &window,
                    &Settings {
                        corner: Corner::Custom,
                        custom_x: x,
                        custom_y: y,
                        ..Settings::default()
                    },
                );
            }
        });
        gesture.connect_drag_update({
            let window = window.downgrade();
            let moved = moved.clone();
            let origin = origin.clone();
            move |_, dx, dy| {
                let Some(window) = window.upgrade() else {
                    return;
                };
                if dx.abs() + dy.abs() < 3.0 {
                    return;
                }
                let Some(monitor) = window.surface().and_then(|surface| {
                    gtk::prelude::WidgetExt::display(&window).monitor_at_surface(&surface)
                }) else {
                    return;
                };
                let bounds = monitor.geometry();
                let x = (origin.get().0 + dx.round() as i32)
                    .clamp(0, (bounds.width() - window.width()).max(0));
                let y = (origin.get().1 + dy.round() as i32)
                    .clamp(0, (bounds.height() - window.height()).max(0));
                window.set_margin(Edge::Left, x);
                window.set_margin(Edge::Top, y);
                moved.set(true);
            }
        });
        gesture.connect_drag_end({
            let window = window.downgrade();
            move |_, _, _| {
                let Some(window) = window.upgrade() else {
                    return;
                };
                if moved.get()
                    && let Some(app) = window.application()
                {
                    app.activate_action(
                        "placement",
                        Some(
                            &(
                                "custom",
                                window.margin(Edge::Left),
                                window.margin(Edge::Top),
                            )
                                .to_variant(),
                        ),
                    );
                }
            }
        });
        handle.add_controller(gesture);
    }
}

//! Placing the widget on the desktop.
//!
//! On compositors with `wlr-layer-shell` (KDE Plasma, Hyprland, Sway, niri,
//! COSMIC, …) the window becomes a real desktop widget: it sits below other
//! windows and is anchored to a screen corner. Everywhere else (GNOME, X11) it
//! stays a borderless window you can drag around.

/// Distance from the screen edges, in logical pixels.
#[cfg(feature = "layer-shell")]
const EDGE_MARGIN: i32 = 20;

/// Must run before the window is first presented.
#[cfg_attr(not(feature = "layer-shell"), allow(unused_variables))]
pub fn place(window: &gtk::ApplicationWindow) {
    #[cfg(feature = "layer-shell")]
    if gtk4_layer_shell::is_supported() {
        pin(window);
    }
}

#[cfg(feature = "layer-shell")]
fn pin(window: &gtk::ApplicationWindow) {
    use gtk4_layer_shell::{KeyboardMode, Layer, LayerShell};

    window.init_layer_shell();
    window.set_namespace(Some("megalith-widgets"));
    window.set_layer(Layer::Bottom);
    window.set_keyboard_mode(KeyboardMode::OnDemand);

    let (vertical, horizontal) = corner();
    for edge in [vertical, horizontal] {
        window.set_anchor(edge, true);
        window.set_margin(edge, EDGE_MARGIN);
    }
}

/// Reads `MEGALITH_WIDGETS_CORNER` (`top-left`, `top-right`, `bottom-left`,
/// `bottom-right`); defaults to the top-right corner.
#[cfg(feature = "layer-shell")]
fn corner() -> (gtk4_layer_shell::Edge, gtk4_layer_shell::Edge) {
    use gtk4_layer_shell::Edge;

    let corner = std::env::var("MEGALITH_WIDGETS_CORNER").unwrap_or_default();
    let vertical = if corner.starts_with("bottom") {
        Edge::Bottom
    } else {
        Edge::Top
    };
    let horizontal = if corner.ends_with("left") {
        Edge::Left
    } else {
        Edge::Right
    };
    (vertical, horizontal)
}

//! Stylesheets, light/dark palettes and the bundled fonts.

use adw::prelude::*;
use gtk::{gdk, glib};
use std::path::Path;

const DARK: &str = include_str!("../../data/style/palette-dark.css");
const LIGHT: &str = include_str!("../../data/style/palette-light.css");
const STYLE: &str = include_str!("../../data/style/style.css");

const ICON_PATH: &str = "/dev/megalith/MegalithWidgets/icons";

macro_rules! font {
    ($name:literal) => {
        ($name, include_bytes!(concat!("../../data/fonts/", $name)))
    };
}

/// Zed's UI and buffer fonts, so the widget looks the same whether or not
/// they are installed system-wide.
const FONTS: &[(&str, &[u8])] = &[
    font!("IBMPlexSans-Regular.ttf"),
    font!("IBMPlexSans-Medium.ttf"),
    font!("IBMPlexSans-SemiBold.ttf"),
    font!("Lilex-Regular.ttf"),
    font!("Lilex-Medium.ttf"),
];

pub fn load() {
    let display = gdk::Display::default().expect("no display");
    gtk::IconTheme::for_display(&display).add_resource_path(ICON_PATH);
    register_fonts();

    let palette = gtk::CssProvider::new();
    let style = gtk::CssProvider::new();
    let priority = gtk::STYLE_PROVIDER_PRIORITY_APPLICATION;
    gtk::style_context_add_provider_for_display(&display, &palette, priority);
    gtk::style_context_add_provider_for_display(&display, &style, priority);

    let manager = adw::StyleManager::default();
    let apply = move |manager: &adw::StyleManager| {
        palette.load_from_string(if manager.is_dark() { DARK } else { LIGHT });
    };
    apply(&manager);
    manager.connect_dark_notify(apply);
    style.load_from_string(STYLE);
}

/// Pango can only load fonts from files, so the embedded copies are written
/// to the cache directory once and registered from there.
fn register_fonts() {
    let Some(font_map) = gtk::Label::new(None).pango_context().font_map() else {
        return;
    };
    let dir = glib::user_cache_dir()
        .join(env!("CARGO_PKG_NAME"))
        .join("fonts");
    if let Err(err) = std::fs::create_dir_all(&dir) {
        eprintln!("couldn't create {}: {err}", dir.display());
        return;
    }
    for (name, bytes) in FONTS {
        let path = dir.join(name);
        if let Err(err) = write_if_changed(&path, bytes) {
            eprintln!("couldn't write {}: {err}", path.display());
            continue;
        }
        if let Err(err) = font_map.add_font_file(&path) {
            eprintln!("couldn't load {}: {err}", path.display());
        }
    }
}

fn write_if_changed(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    match std::fs::metadata(path) {
        Ok(meta) if meta.len() == bytes.len() as u64 => Ok(()),
        _ => std::fs::write(path, bytes),
    }
}

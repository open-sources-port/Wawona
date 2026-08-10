//! XDG Popup protocol implementation.
//!
//! This implements the xdg_popup protocol from the xdg-shell extension.
//! It provides the interface for managing popup surfaces (menus, tooltips, etc.).

use crate::core::wayland::protocol::server::xdg::shell::server::xdg_popup;
use wayland_server::{Dispatch, DisplayHandle, Resource};

use crate::core::state::CompositorState;

impl Dispatch<xdg_popup::XdgPopup, u32> for CompositorState {
    fn request(
        state: &mut Self,
        _client: &wayland_server::Client,
        resource: &xdg_popup::XdgPopup,
        request: xdg_popup::Request,
        _data: &u32,
        _dhandle: &DisplayHandle,
        _data_init: &mut wayland_server::DataInit<'_, Self>,
    ) {
        let popup_id = resource.id().protocol_id();
        let client_id = _client.id();

        match request {
            xdg_popup::Request::Destroy => {
                tracing::debug!("xdg_popup destroyed: {}", popup_id);
                if let Some(data) = state.xdg.popups.remove(&(client_id.clone(), popup_id)) {
                    // Clean up surface_to_window mapping
                    state.surface_to_window.remove(&data.surface_id);

                    // Remove from grab stack if present
                    state
                        .seat
                        .popup_grab_stack
                        .retain(|(ref cid, ref pid)| cid != &client_id || *pid != popup_id);

                    // CRITICAL: Emit event for FFI layer cleanup
                    state.pending_compositor_events.push(
                        crate::core::compositor::CompositorEvent::WindowDestroyed {
                            window_id: data.window_id,
                        },
                    );
                }
            }
            xdg_popup::Request::Grab { seat: _, serial: _ } => {
                tracing::debug!("xdg_popup.grab requested for popup {}", popup_id);
                if let Some(data) = state.xdg.popups.get_mut(&(client_id.clone(), popup_id)) {
                    data.grabbed = true;
                    // Push to grab stack
                    if !state
                        .seat
                        .popup_grab_stack
                        .contains(&(client_id.clone(), popup_id))
                    {
                        state
                            .seat
                            .popup_grab_stack
                            .push((client_id.clone(), popup_id));
                    }
                    tracing::debug!("Popup {} added to grab stack", popup_id);
                }
            }
            xdg_popup::Request::Reposition { positioner, token } => {
                tracing::debug!("xdg_popup.reposition requested for popup {}", popup_id);

                // Get positioner data
                let positioner_data = state
                    .xdg
                    .positioners
                    .get(&(client_id.clone(), positioner.id().protocol_id()))
                    .cloned()
                    .unwrap_or_default();

                // Get output dimensions
                let (ox, oy, initial_width, initial_height, _) = {
                    let output = state.primary_output();
                    (
                        output.x,
                        output.y,
                        output.width,
                        output.height,
                        output.scale,
                    )
                };
                let output_rect =
                    crate::util::geometry::Rect::new(ox, oy, initial_width, initial_height);

                let surface_id =
                    if let Some(data) = state.xdg.popups.get_mut(&(client_id.clone(), popup_id)) {
                        // Calculate new position using anchor/gravity rules
                        let (px, py) = positioner_data.calculate_position(output_rect);

                        // Update geometry
                        data.geometry = (px, py, positioner_data.width, positioner_data.height);
                        data.anchor_rect = positioner_data.anchor_rect;
                        data.repositioned_token = Some(token);

                        // CRITICAL: Emit event for FFI layer to reposition the platform window
                        state.pending_compositor_events.push(
                            crate::core::compositor::CompositorEvent::PopupRepositioned {
                                window_id: data.window_id,
                                x: px,
                                y: py,
                                width: data.geometry.2 as u32,
                                height: data.geometry.3 as u32,
                            },
                        );

                        // Send repositioned event
                        resource.repositioned(token);

                        // Send configure
                        resource.configure(px, py, data.geometry.2, data.geometry.3);

                        Some(data.surface_id)
                    } else {
                        None
                    };

                // Trigger surface configure to apply changes
                if let Some(sid) = surface_id {
                    let serial = state.next_serial();
                    let xdg_surface_id = state
                        .xdg
                        .popups
                        .get(&(client_id.clone(), popup_id))
                        .map(|p| p.xdg_surface_id)
                        .unwrap_or(sid);
                    if let Some(surface_data) =
                        state.xdg.surfaces.get_mut(&(client_id, xdg_surface_id))
                    {
                        surface_data.pending_serial = serial;
                        surface_data.pending_serials.push(serial);
                        if let Some(surface_resource) = &surface_data.resource {
                            surface_resource.configure(serial);
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

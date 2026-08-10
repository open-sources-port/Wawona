//! XDG Activation protocol implementation.
//!
//! This protocol allows clients to request activation (focus) for a surface,
//! using activation tokens to prevent focus stealing.

use wayland_protocols::xdg::activation::v1::server::{
    xdg_activation_token_v1::{self, XdgActivationTokenV1},
    xdg_activation_v1::{self, XdgActivationV1},
};
use wayland_server::{Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource};

use crate::core::state::CompositorState;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct ActivationTokenData {
    pub token: String,
    pub app_id: Option<String>,
    pub serial: Option<u32>,
    pub surface_id: Option<u32>,
}

impl Default for ActivationTokenData {
    fn default() -> Self {
        use std::time::{SystemTime, UNIX_EPOCH};
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let token = format!("muplar-wayland-{:x}", now);
        Self {
            token,
            app_id: None,
            serial: None,
            surface_id: None,
        }
    }
}

#[derive(Debug, Default)]
pub struct ActivationState {
    pub tokens: HashMap<(wayland_server::backend::ClientId, u32), ActivationTokenData>,
}

// ============================================================================
// xdg_activation_v1
// ============================================================================

impl GlobalDispatch<XdgActivationV1, ()> for CompositorState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<XdgActivationV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
        tracing::debug!("Bound xdg_activation_v1");
    }
}

impl Dispatch<XdgActivationV1, ()> for CompositorState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &XdgActivationV1,
        request: xdg_activation_v1::Request,
        _data: &(),
        _dhandle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            xdg_activation_v1::Request::GetActivationToken { id } => {
                let token_data = ActivationTokenData::default();
                let token = data_init.init(id, ());
                let client_id = _client.id();
                state
                    .xdg
                    .activation
                    .tokens
                    .insert((client_id, token.id().protocol_id()), token_data);

                tracing::debug!("Created activation token");
            }
            xdg_activation_v1::Request::Activate { token, surface } => {
                let surface_id = surface.id().protocol_id();
                tracing::debug!(
                    "Activate request for surface {} with token {}",
                    surface_id,
                    token
                );

                // Validate the token exists
                let token_valid = state
                    .xdg
                    .activation
                    .tokens
                    .values()
                    .any(|t| t.token == token);

                if !token_valid {
                    tracing::warn!("Activation denied: unknown token {}", token);
                } else {
                    // Find window for the surface
                    let window_id = state.surface_to_window.get(&surface_id).copied();
                    if let Some(wid) = window_id {
                        tracing::info!(
                            "Activating window {} via xdg_activation token {}",
                            wid,
                            token
                        );

                        // Emit event for platform to raise the window
                        state.pending_compositor_events.push(
                            crate::core::compositor::CompositorEvent::WindowActivationRequested {
                                window_id: wid,
                            },
                        );

                        // Set focus to the activated window
                        state.set_focused_window(Some(wid));

                        // Mark the toplevel as activated and send configure
                        let mut to_configure = None;
                        for ((cid, tl_proto_id), tl_data) in state.xdg.toplevels.iter() {
                            if tl_data.window_id == wid {
                                to_configure = Some((
                                    cid.clone(),
                                    *tl_proto_id,
                                    tl_data.width,
                                    tl_data.height,
                                ));
                                break;
                            }
                        }

                        if let Some((cid, tl_id, w, h)) = to_configure {
                            if let Some(tl) = state.xdg.toplevels.get_mut(&(cid.clone(), tl_id)) {
                                tl.activated = true;
                            }
                            state.send_toplevel_configure(cid, tl_id, w, h);
                        }
                    } else {
                        tracing::warn!("Activation: no window found for surface {}", surface_id);
                    }
                }
            }
            xdg_activation_v1::Request::Destroy => {
                tracing::debug!("xdg_activation_v1 destroyed");
            }
            _ => {}
        }
    }
}

// ============================================================================
// xdg_activation_token_v1
// ============================================================================

impl Dispatch<XdgActivationTokenV1, ()> for CompositorState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &XdgActivationTokenV1,
        request: xdg_activation_token_v1::Request,
        _data: &(),
        _dhandle: &DisplayHandle,
        _data_init: &mut wayland_server::DataInit<'_, Self>,
    ) {
        let token_id = resource.id().protocol_id();
        let client_id = _client.id();

        match request {
            xdg_activation_token_v1::Request::SetSerial { serial, seat: _ } => {
                if let Some(data) = state
                    .xdg
                    .activation
                    .tokens
                    .get_mut(&(client_id.clone(), token_id))
                {
                    data.serial = Some(serial);
                    tracing::debug!("Set serial {} for activation token", serial);
                }
            }
            xdg_activation_token_v1::Request::SetAppId { app_id } => {
                if let Some(data) = state
                    .xdg
                    .activation
                    .tokens
                    .get_mut(&(client_id.clone(), token_id))
                {
                    data.app_id = Some(app_id.clone());
                    tracing::debug!("Set app_id {} for activation token", app_id);
                }
            }
            xdg_activation_token_v1::Request::SetSurface { surface } => {
                let surface_id = surface.id().protocol_id();
                if let Some(data) = state
                    .xdg
                    .activation
                    .tokens
                    .get_mut(&(client_id.clone(), token_id))
                {
                    data.surface_id = Some(surface_id);
                    tracing::debug!("Set surface {} for activation token", surface_id);
                }
            }
            xdg_activation_token_v1::Request::Commit => {
                // Send the token back to the client
                if let Some(data) = state
                    .xdg
                    .activation
                    .tokens
                    .get(&(client_id.clone(), token_id))
                {
                    resource.done(data.token.clone());
                    tracing::debug!("Committed activation token: {}", data.token);
                }
            }
            xdg_activation_token_v1::Request::Destroy => {
                state.xdg.activation.tokens.remove(&(client_id, token_id));
                tracing::debug!("xdg_activation_token_v1 destroyed");
            }
            _ => {}
        }
    }
}

/// Register xdg_activation_v1 global
pub fn register_xdg_activation(display: &DisplayHandle) -> wayland_server::backend::GlobalId {
    display.create_global::<CompositorState, XdgActivationV1, ()>(1, ())
}

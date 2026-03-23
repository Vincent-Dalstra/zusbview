const std = @import("std");

// Every device, hub and root_hub always has a :1.0 endpoint, so it's not meaningful to draw it
pub const hide_mandatory_endpoint = true;

CREATE INDEX IF NOT EXISTS idx_messages_room_id_desc
    ON messages (room_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_room_members_user_room
    ON room_members (user_id, room_id);
CREATE INDEX IF NOT EXISTS idx_library_categories_parent_name_id
    ON library_categories (parent_id, name, id);
CREATE INDEX IF NOT EXISTS idx_library_items_category_created_id
    ON library_items (category_id, created_at DESC, id DESC);

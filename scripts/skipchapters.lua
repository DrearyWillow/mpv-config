local options = require 'mp.options'

local o = {
    skip_chapter_list = dofile('/home/kyler/.config/mpv/scripts/.utils/chapters_to_skip.lua'),
}
options.read_options(o)

function check_chapter(_, chapter)
    if not chapter then
        return
    end
    for _, p in pairs(o.skip_chapter_list) do
        if string.match(chapter, p) then
            print("Skipping chapter:", chapter)
            mp.command("no-osd add chapter 1")
            return
        end
    end
end

mp.observe_property("chapter-metadata/by-key/title", "string", check_chapter)
-- pokemon_bw_reader.lua -- PLACEHOLDER. This is NOT the accessibility reader.
--
-- The real Pokemon Black/White reader is a large third-party script with no established
-- redistribution licence, so it is deliberately not part of this public build kit. The core
-- embeds this placeholder in its place purely so that the build has an input file; the core's
-- normal search order is unchanged and still finds the real reader first:
--
--     1. <directory containing the core library>/melondsds_access/pokemon_bw_reader.lua
--     2. <RetroArch system directory>/melondsds_access/pokemon_bw_reader.lua
--     3. this embedded placeholder
--
-- So: copy the real pokemon_bw_reader.lua into the melondsds_access folder inside RetroArch's
-- system folder and reload the game. Nothing in the core needs to be rebuilt.
--
-- If execution reaches this file, the reader is missing. It must say so out loud rather than
-- sit there silently pretending to read a game, so it raises an error immediately. The core
-- logs that error and speaks "Accessibility reader stopped. <message>" through whichever speech
-- backend is configured.

local MESSAGE =
    "The Pokemon reader script is not included in this build. " ..
    "Copy pokemon_bw_reader.lua into the melondsds_access folder inside RetroArch's system folder, " ..
    "then reload the game."

-- print() is a host global provided by the core; it goes to the RetroArch log.
if type(print) == "function" then
    print("[placeholder reader] " .. MESSAGE)
end

-- Level 0: no "file:line:" prefix, so the message the player hears is exactly the message above.
-- The core takes the first line of the error, up to 240 characters, as the spoken text.
error(MESSAGE, 0)

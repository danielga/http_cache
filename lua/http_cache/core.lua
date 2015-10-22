-- initialization block
file.CreateDir("http_cache")

if sql.Query([[
	CREATE TABLE IF NOT EXISTS `http_cache` (
		`URL` TEXT PRIMARY KEY NOT NULL,
		`Name` TEXT NOT NULL UNIQUE,
		`ETag` TEXT,
		`LastModified` TEXT,
		`LastValidation` INTEGER NOT NULL,
		`MaxAge` INTEGER NOT NULL,
		`CRC32` INTEGER NOT NULL
	)
]]) == false then
	error(sql.LastError())
end
-- end of initialization block

http_cache = {}
local http_cache = http_cache

include("file.lua")

local timezone_difference = os.time() - os.time(os.date("!*t"))
local function GetUTCTime()
	return os.time() - timezone_difference
end

http_cache.GetUTCTime = GetUTCTime

-- taken from https://github.com/Tieske/uuid
local lua_version = tonumber(string.match(_VERSION, "%d%.*%d*"))
local time = SysTime or os.clock or os.time
local function randomseed()
	local seed = math.floor(math.abs(time() * 10000))
	if seed >= 2 ^ 32 then
		-- integer overflow, so reduce to prevent a bad seed
		seed = seed - math.floor(seed / 2 ^ 32) * (2 ^ 32)
	end

	if lua_version < 5.2 then
		-- 5.1 uses (incorrect) signed int
		math.randomseed(seed - 2 ^ (32 - 1))
	else
		-- 5.2 uses (correct) unsigned int
		math.randomseed(seed)
	end
end

local valid_characters = {
	"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
	"0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
	"-", "_", " ", "!", "@", "#", "$", "%", "^", "&", "(", ")", "=", "+", ";", "'", ",", "~", "`", "[", "]", "{", "}"
}
local function GenerateRandomName()
	randomseed()

	local v = valid_characters
	local s = #valid_characters
	local r = math.random
	return -- 32 bytes of valid filesystem characters (59 valid characters)
		v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] ..
		v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] ..
		v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] ..
		v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)] .. v[r(1, s)]
end

http_cache.GenerateRandomName = GenerateRandomName

--[[
local function GenerateUUID()
	randomseed()

	return string.format(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255),
		math.random(0, 255), math.random(0, 255),
		bit.band(math.random(0, 255), 0x0F) + 0x40, math.random(0, 255),
		bit.band(math.random(0, 255), 0x3F) + 0x80, math.random(0, 255),
		math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255)
	)
end

http_cache.GenerateUUID = GenerateUUID
]]

local function StringXOR(str)
	if #str == 0 then
		return ""
	end

	local crc = util.CRC(str)
	local xor = {
		math.floor(crc / 0x1000000) % 0x100,
		math.floor(crc / 0x10000) % 0x100,
		math.floor(crc / 0x100) % 0x100,
		crc % 0x100
	}

	local xstr = ""
	for i = 1, #str do
		xstr = xstr .. string.char(bit.band(bit.bxor(string.byte(str, i, i), xor[(i - 1) % 4 + 1]), 0xFF))
	end

	return xstr
end

http_cache.StringXOR = StringXOR

local function GetInfo(xurl)
	local data = sql.Query("SELECT `Name`, `ETag`, `LastModified`, `LastValidation`, `MaxAge`, `CRC32` FROM `http_cache` WHERE `URL` = " .. sql.SQLStr(xurl))
	if type(data) ~= "table" or data[1] == nil then
		return false
	end

	local entry = data[1]
	entry.LastValidation = tonumber(entry.LastValidation)
	entry.MaxAge = tonumber(entry.MaxAge)
	entry.CRC32 = tonumber(entry.CRC32)
	return entry.Name, entry.ETag, entry.LastModified, entry.LastValidation, entry.MaxAge, entry.CRC32
end

http_cache.GetInfo = GetInfo

local query_simple = "INSERT OR REPLACE INTO `http_cache` (`URL`, `Name`, `LastValidation`, `MaxAge`, `CRC32`) VALUES(%s, %s, %d, %d, %d)"
local query_modified = "INSERT OR REPLACE INTO `http_cache` (`URL`, `Name`, `LastModified`, `LastValidation`, `MaxAge`, `CRC32`) VALUES(%s, %s, %s, %d, %d, %d)"
local query_etag = "INSERT OR REPLACE INTO `http_cache` (`URL`, `Name`, `ETag`, `LastValidation`, `MaxAge`, `CRC32`) VALUES(%s, %s, %s, %d, %d, %d)"
local query_both = "INSERT OR REPLACE INTO `http_cache` (`URL`, `Name`, `ETag`, `LastModified`, `LastValidation`, `MaxAge`, `CRC32`) VALUES(%s, %s, %s, %s, %d, %d, %d)"
local function UpdateInfo(xurl, name, etag, lastmodified, lastvalidation, maxage, crc32)
	local query
	if etag ~= nil and lastmodified ~= nil then
		query = string.format(query_both, xurl, name, etag, lastmodified, lastvalidation, maxage, crc32)
	elseif etag ~= nil then
		query = string.format(query_etag, xurl, name, etag, lastvalidation, maxage, crc32)
	elseif lastmodified ~= nil then
		query = string.format(query_modified, xurl, name, lastmodified, lastvalidation, maxage, crc32)
	else
		query = string.format(query_simple, xurl, name, lastvalidation, maxage, crc32)
	end

	if sql.Query(query) == false then
		print(sql.LastError())
		return false
	end

	return true
end

http_cache.UpdateInfo = UpdateInfo

return http_cache

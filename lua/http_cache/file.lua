local http_cache = http_cache

local FILE = {__index = {}}
local FILE_INDEX = FILE.__index

function FILE_INDEX:Initialize(url)
	self.url = url
	self.xurl = http_cache.StringXOR(url)

	local name, etag, lastmodified, lastvalidation, maxage, crc32 = http_cache.GetInfo(self.xurl)
	if name ~= false then
		local content = file.Read("http_cache/" .. name .. ".dat", "DATA")
		if content == nil or tonumber(util.CRC(content)) ~= crc32 then
			file.Delete("http_cache/" .. name .. ".dat")
			self.name = http_cache.GenerateRandomName()
			return self:Fetch()
		end

		self.name = name
		self.etag = etag
		self.lastmodified = lastmodified
		self.lastvalidation = lastvalidation
		self.maxage = maxage
		self.crc32 = crc32
		self.content = content

		-- verify the output of this
		return not self:IsValid() and self:Fetch()
	end

	self.name = http_cache.GenerateRandomName()
	return self:Fetch()
end

function FILE_INDEX:IsValid()
	return self.lastvalidation ~= nil and self.maxage ~= nil and http_cache.GetUTCTime() - self.lastvalidation < self.maxage
end

function FILE_INDEX:Fetch(force)
	if not force and self:IsValid() then
		return false
	end

	local reqheaders
	if self.etag ~= nil then
		reqheaders = reqheaders or {}
		reqheaders["If-None-Match"] = self.etag
	end

	if self.lastmodified ~= nil then
		reqheaders = reqheaders or {}
		reqheaders["If-Modified-Since"] = self.lastmodified
	end

	http.Fetch(
		self.url,
		function(body, len, resheaders, code)
			self:Success(code, resheaders, body)
		end,
		function(err)
			self:Failure(err)
		end,
		reqheaders
	)
	return true
end

function FILE_INDEX:Success(code, resheaders, body)
	if code ~= 200 and code ~= 304 then
		return self:Failure(code)
	end

	print(self.url, code, #body)
	PrintTable(resheaders)

	self.etag = resheaders["ETag"] or self.etag
	self.lastmodified = resheaders["Last-Modified"] or self.lastmodified

	self.lastvalidation = http_cache.GetUTCTime()
	local maxage = resheaders["Cache-Control"] ~= nil and string.match(resheaders["Cache-Control"], "max%-age=(%d+)")
	self.maxage = maxage ~= nil and tonumber(maxage) or (self.maxage or 0)

	if code == 200 then
		self.crc32 = util.CRC(body)
		self.content = body
		file.Write("http_cache/" .. self.name .. ".dat", body)
	end

	http_cache.UpdateInfo(self.xurl, self.name, self.etag, self.lastmodified, self.lastvalidation, self.maxage, self.crc32)
	return true
end

function FILE_INDEX:Failure(err)
	print(self.url, err)
	return false
end

function http_cache.Create(url)
	local obj = setmetatable({}, FILE)
	obj:Initialize(url)
	return obj
end

return http_cache.Create

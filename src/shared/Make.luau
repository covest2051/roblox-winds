--[[
	Make — короткое создание инстансов:
	  Make("Part", { Size = ..., Parent = folder }, { Make("PointLight", {...}) })
	Parent применяется последним (так быстрее и без лишней репликации).
]]

local function Make(className: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(className)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			elseif k == "Attributes" then
				for an, av in v do
					inst:SetAttribute(an, av)
				end
			elseif k == "Tags" then
				for _, tag in v do
					inst:AddTag(tag)
				end
			else
				(inst :: any)[k] = v
			end
		end
	end
	if children then
		for _, c in children do
			c.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

return Make

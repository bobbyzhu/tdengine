-- accountd.lua
-- Created by wugd
-- 负责玩家相关的功能模块

-- 声明模块名
module("ACCOUNT_D", package.seeall);

-- 创建弱引用表
local account_list = {};
setmetatable(account_list, { __mode = "v" });

-- 创建玩家
function create_account(dbase)
    local account = ACCOUNT_CLASS.new(dbase);
    account_list[#account_list + 1] = account;
    return account;
end

-- 冻结玩家记录
function hiberate(user, save_callback)

end


-- 新增玩家记录的回调
local function create_new_account_callback(info, ret, result_list)
    local account_ob = info["account_ob"];
    if ret ~= 0 then
        do return; end
    end

    login(account_ob, info["rid"], info);
end

function login(agent, account_rid, account_dbase)
    assert(account_rid == account_dbase["rid"]);
    local account = create_account(account_dbase);
    account:accept_relay(agent)
    account:send_message(MSG_LOGIN_NOTIFY_STATUS, {ret = 0})
    success_login(account, false)
end

function success_login(account, is_reconnect)
    if not account:get_user_ob() then
        is_reconnect = false
    end
    account:set_server_type(SERVER_TYPE_CLIENT)
    account:set_authed(true)

    if is_reconnect then
        account:set_login_user(account:get_user_ob(), is_reconnect)
    elseif IS_SINGLE then
        ACCOUNT_D.get_user_list(account)
    end
end

-- 创建 user 表记录
function create_new_account(login_info)
    local agent = login_info["agent"];
    local device_id = login_info["device_id"]

    if not is_object(agent) then
        return;
    end

    -- 检查信息是否合法
    if not is_string(device_id) then
        trace("创建新角色信息不合法。\n")
        return;
    end

    local user_rid = NEW_RID();

    -- 记录其它必备的玩家属性
    local account_dbase = {
        rid         = user_rid,
        name        = login_info["name"],
        create_time = os.time(),
        account     = login_info["account"],
        device_id   = device_id,
        password    = login_info["password"],
        switch_time = 0,
        device_md5  = calc_str_md5(device_id),
    };
    local sql = SQL_D.insert_sql("account", account_dbase)
    account_dbase["account_ob"] = agent
    DB_D.execute_db("account", sql, create_new_account_callback, account_dbase)
end

function get_account_list()
    return account_list;
end

function account_logout(account)
    if not is_object(account) then
        return;
    end
    destruct_object(account);
end

local function callback_get_user_list(account, ret, result_list)
    account:send_message(MSG_USER_LIST, result_list or {})

    local user_list = {}
    for _,value in ipairs(result_list) do
        user_list[value["rid"]] = value
    end
    account:set("user_list", user_list)
    if IS_SINGLE then
        local rid, value = get_first_key_value(user_list)
        if value and value.ban_flag and value.ban_flag ~= 0 then
            account:send_message(MSG_LOGIN_NOTIFY_STATUS, {ret = -1, err_msg = "账号被冻结"})
            account:connection_lost(true)
            return
        end
        if rid then
            request_select_user(account, rid)
        else
            local user_rid = NEW_RID()
            request_create_user(account, {
                name = "auto_" .. user_rid, --RANDOM_NAMED.generate_random_name(), --"auto_" .. user_rid,
                rid  = user_rid,
            })
        end
    end
end

function get_user_list(account)
    local sql = SQL_D.select_sql("user", {_WHERE={account_rid=account:query("rid")}})
    DB_D.read_db("user", sql, callback_get_user_list, account)
end

local function create_new_user_callback(info, ret, result_list)
    local account_ob = info["account_ob"]
    info["account_ob"] = nil
    if ret ~= 0 then
        account_ob:send_message(MSG_CREATE_USER, {status=1})
        destruct_object(account_ob)
        do return; end
    end
    account_ob:send_message(MSG_CREATE_USER, {status=0})
    info["status"] = 0
    local user_list = account_ob:query("user_list")
    if not user_list then
        user_list = {}
        account_ob:set("user_list", user_list)
    end

    local table_data= {rid=info.rid, name = info.name, fight= info.fight,
        watch_rids = info.watch_rids, zone = info.zone, ban_flag = info.ban_flag, vip= info.vip ,
        lv= info.lv, head_icon= info.head_icon, head_photo_frame= info.head_photo_frame,
        last_login_time= info.last_login_time, last_logout_time= info.last_logout_time }
    USER_D.publish_user_attr_update(table_data)

    user_list[info.rid] = info
    LOG_D.to_log(LOG_TYPE_CREATE_NEW_USER, info.rid, account_ob:query("name"), "", "");

    raise_issue(EVENT_NEW_USER_CREATE, info)
    request_select_user(account_ob, info.rid)
end

function request_create_user(account, info)
    local user_dbase = {
        rid         = info.rid or NEW_RID(),
        name        = info.name,
        ban_flag    = 0,
        sp          = 50,
        gold        = 0,
        stone       = 0,
        create_time = os.time(),
        account_rid = account:query("rid"), 
        vip= 0,
        lv= 1, 
        last_login_time= os.time(),
        last_logout_time= 0,
    }

    trace("user_dbase %o \n", user_dbase)
    local sql = SQL_D.insert_sql("user", user_dbase)
    user_dbase["account_ob"] = account
    DB_D.execute_db("account", sql, create_new_user_callback, user_dbase)
end


local function read_user_callback(info, args)
    local rid, account = args["rid"], args["account"]
    assert(rid ~= nil, "rid must not nil")
    -- local user = find_object_by_rid(rid)
    -- assert(user ~= nil, "user must not nil")
    if info.failed then
        return
    end

    local user = info.user
    for key, value in pairs(user or {}) do
        info[key] = value
    end
    info.user = nil

    local user_ob = find_object_by_rid(rid)
    if user_ob then
        user_ob:close_agent()
    else
        user_ob = USER_D.create_user(info)
    end
    
    account:set_login_user(user_ob)
end

function request_select_user(account, rid)
    local user_list = account:query("user_list") or {}
    if user_list[rid] == nil then
        return
    end

    local user_ob = find_object_by_rid(rid)
    --断线重连
    if user_ob then
        account:set_login_user(user_ob)
    else
        CACHE_D.get_user_data(rid, read_user_callback, {rid = rid, account = account})
    end
end


local function init()
end

function create()
    register_post_init(init)
end

create();

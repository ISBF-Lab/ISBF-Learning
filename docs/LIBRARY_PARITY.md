# 资料库与课程资源共用流程

资料库的管理表单、学号关联、我的贡献、目录编辑和确认后软删除流程与课程资源一致，显示名称使用分类和分组。课程资源原有接口继续使用其默认范围。资源、目录、搜索、贡献归属和收集表单的存储分别独立。

- `isbf_library_collection_form_url`：独立收集表单地址，初始值采用课程资源现有 WPS 地址；后续修改一个设置不改变另一个设置。
- `PUT /isbf/library/collection-form`：使用已有资源管理权限修改该地址，保留原生设置审计。
- `GET /isbf/library/contributions`：按当前会话账号读取已发布的资料库贡献，不接收用户 ID 来切换查询账号。
- `GET /isbf/library/contributor-users`：复用课程资源的管理权限与精确学号查询；身份字段只向管理者返回。
- `PUT /isbf/library/resources/:id`：复用课程资源的修订流程，保留作者、资源 ID 和原生历史；分组参数为 `group_id`。
- `PUT /isbf/library/groups/:id`：更新分组名和所属分类，保留 UUID；所属分类以共用编辑表单的 `grade` 字段传递。
- `PUT /isbf/library/categories/:id`：修改分类名称，保留 UUID。
- `GET /isbf/library/{groups|categories}/:id/deletion-plan` 及对应 `DELETE`：复用目录删除预览和两次或三次确认，校验操作者、目录及资源摘要和时效；目录归档，资料使用原生软删除，不删除审核记录或私有文件。

后续合并须保留本插件独立的 `isbf_library_*` 字段、目录锁、管理与审核两个授权、审计和确认令牌。主题需与这些新增能力同时采用，不能只接入“我的贡献”按钮却遗漏其资料库接口。关闭资料库即可隐藏入口；代码回滚仍须保留已经注册的审核类型和全部历史数据。

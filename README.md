# ISBF Learning

Discourse 学习资源库插件。课程与资源入口为 `/isbf/learning`，主题、回复、审核和搜索复用 Discourse。课程按大一至大四归类；staff 可直接添加，普通成员可申请并由 staff 在原生 `/review` 批准或拒绝。已登录成员可以阅读资源并提交材料。普通成员的提交进入原生审核队列，staff 可直接发布。审核通过后，普通作者不能修改资源首帖，staff 可通过原生编辑功能维护内容。

## 配置与数据

- `isbf_learning_enabled`：资源库开关。
- `isbf_learning_category_id`：实际存在的资源分类 ID，不依赖固定 slug 或分类编号。
- `isbf_learning_storage_limit_mb`：私有附件存储上限，默认 512 MiB。

资源分类应限制为 `trust_level_0` 和 `staff` 拥有完整权限，避免向匿名访客开放；插件仍通过 Guardian 检查实际分类访问权限。插件仅在该资源分类内允许已激活、已批准且未被禁言或封禁的成员提交，保留原生审核，不修改全站 `create_topic_allowed_groups`。配置后在 Staging 核查访客、普通成员、staff 的真实读写与审核行为。

课程目录和附件元数据保存在 `PluginStore` 的 `isbf-learning` 命名空间。资源为原生 Topic/Post，首帖创建时写入课程、文件、外链和选填简介的 Topic custom fields；审核完整保留这些字段。资源必须提供明确标题，并至少包含一个受保护附件链接或合法 HTTP(S) 外链。原生公共 `/uploads/` 和 `upload://` 附件不能作为资源库私有材料提交。

## 接口

登录后可使用 `GET /isbf/learning/courses` 获取 `{courses: [...]}`。`POST /isbf/learning/courses` 接受 `name` 与 `grade`（1 至 4）：staff 返回 `{success: true, pending: false, course: {...}}`；普通成员返回 `{success: true, pending: true, reviewable_id: ...}`，审批前不写入目录。同一申请人重复提交相同待审核申请复用原记录；拒绝后可重新申请。目录内已有同年级同名课程或非法值返回 422。

课程申请使用原生 `ReviewableIsbfLearningCourse` 和审核权限，ISBF-UI 通过官方 `registerReviewableComponent` 展示课程及年级。批准和目录写入受同一分布式互斥锁保护，锁覆盖原生审核事务的提交；不同用户申请同一课程时，批准复用已存在课程。写入失败不会批准申请，审核事务失败同时回滚目录。禁言、封禁、未获准及无分类权限的账号不能申请。

`GET /isbf/learning/resources` 接受 `course_id`、`page` 和 `q`，返回 `resources` 与 `has_more`。普通列表按课程查询；有 `q` 时使用 Core Search 搜索资源库全部年级与课程，忽略当前课程筛选。两种查询均仅覆盖配置资源分类内当前用户可以访问的已发布资源。

分享窗口按标题、选填简要介绍和链接排列，使用 `POST /isbf/learning/resources`，参数为 `course_id`、`title`、`description`（可选）、`link`。简介最多 300 个 Unicode 字符，支持换行；服务端拒绝超长、非字符串和非法控制字符，保存后按纯文本显示在资料标题下方，并参与限定学习库范围的原生搜索。空简介与历史资料保持原样。课程沿用页面当前选项。接口固定学习分类，不接受正文、标签、附件或其他话题参数；外链必须是完整 HTTP(S) 地址，最多 2048 字符，不接受本站链接、内嵌凭据或空白字符。返回 `success`、`pending` 和已发布的 `resource`；普通成员先进入原生 Reviewable，审核通过前不会出现资料卡片。

服务端仍使用原生 NewPostManager、Topic/Post 和审核流程。新资料保存 `isbf_learning_link` 和 `isbf_learning_description`，审核 payload 保留这些字段，卡片标题直接打开链接，不重复显示内部正文。原生主题标题校验继续生效。历史附件资料与原生 staff 编辑功能保留，原有 `POST /posts` 的资源字段仍受分类、身份、附件权限和审核限制。

配置的学习分类从 TopicQuery 默认查询中排除，包含最新、热门、排行榜、筛选及直接分类列表，普通成员和 staff 均适用。资料库使用自己的受权限控制的列表和限定范围的原生搜索；已有资料也不会出现在首页、探索或右栏最近讨论。审核队列、直接主题读取及全站搜索不因该列表排除而改变。

## 附件保护与备份

附件保存在 `/shared/isbf-learning-private`，通过登录后受权限控制的 `/isbf/learning/files/:uuid` 下载，不创建公共 Discourse Upload。部署时必须把此目录保存在持久存储，并确认其不在 Web 服务器静态文件公开范围。可用 `ISBF_LEARNING_STORAGE_PATH` 指定独立私有存储目录；不要配置到公开上传目录。

未绑定或待审核附件仅允许上传者和 staff 访问；已发布附件还必须通过资源主题的 Guardian 权限与可见状态检查。资源被删除、隐藏、取消可见或进入严重违规处理状态时，普通用户的附件访问撤销，包括原作者。外部链接的访问控制由外部站点决定，插件不能撤销已下载的副本，也不能把公开外链变成私有文件。

数据库备份必须与私有附件目录备份配套：数据库包含课程、文件元数据及资源关联，私有目录包含实际文件。默认 Discourse 上传备份不能被视为已经包含此独立目录。GitHub 仅保存代码。上线前确认备份与恢复流程，并在恢复后核查关联和下载权限。禁用插件不会删除已有主题、元数据或私有文件；回滚代码应保留这些数据。已有任何 `ReviewableIsbfLearningCourse` 记录时，禁止回退到未注册该类型的旧插件版本：Core 对未知审核类型的处理可能删除记录。可先恢复旧主题，同时保留新审核类型，再部署向前修复；不得通过删除申请记录完成回滚。

## 验证

GitHub Actions 通过 Discourse 官方插件测试工作流执行 Rails RSpec，Core 固定为可获取的上游提交 `f18a1985b22e5d4c0a0fffd6f91812105467afdb`。站点自有 Core 的版本另随发布备份保存，因此此 CI 不等同于域名站点的运行回归。另有 Ruby 语法检查。CI 需要官方工作流提供的 Ruby、PostgreSQL、Redis 和 Discourse 测试依赖；这是独立测试 checkout，不是已有服务器容器。

可在该 Core 的独立测试 checkout 中运行：

```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/isbf-learning/spec
```

测试覆盖课程权限、原生审核及元数据保留、首帖编辑限制、非法提交、资源查询范围和附件存储/访问约束。本机未启动完整 Discourse，未执行 Rails 集成测试或浏览器回归；语法检查不能证明实际 UI、移动端、亮暗模式、Admin 隔离或部署后的文件下载行为。合并部署前须由 CI 和 Staging 验证。

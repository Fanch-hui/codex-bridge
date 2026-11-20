package redact

import (
	_ "embed"
	"strings"
	"unicode"
	"unicode/utf8"
)

const zhSurnames = "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖萧田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付傅方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛曲翁冉骆蓝路游辛靳管柴蒙鲍华喻祁蒲房滕屈饶解牟艾尤阳时穆农司卓古吉缪简车项连芦麦褚娄窦戚岑景党宫费卜冷晏席卫米柏宗瞿桂全佟应臧闵苟邬边卞姬师仇栾隋商刁沙荣巫寇桑郎甄丛仲虞敖巩佘池查麻苑迟邝"

var zhCompound = []string{"欧阳", "司马", "上官", "诸葛", "东方", "皇甫", "尉迟", "公孙", "慕容", "令狐", "司徒", "夏侯", "长孙", "宇文", "轩辕", "端木", "独孤", "南宫", "西门", "钟离", "呼延", "申屠", "闻人", "澹台", "拓跋", "万俟"}

const zhNickSurnames = "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘蒋蔡杜叶程苏魏吕丁沈姚卢姜崔钟谭陆汪范金廖贾夏方邹孟熊秦江薛段雷侯史陶贺顾毛郝龚邵钱严武戴孔汤"

const zhNotGiven = "的了在是和与跟同说他她它我你您们这那个不也都就还把被给到对从向为以等及或并而吗呢吧啊去来有没要会能让请已将再又很更最先后上下里外时年日号发打回写问讲叫找用做看想知道得地着过之其此每各某该所反表认提负"

var zhWords = runes2(
	"张量", "张开", "张贴", "高度", "高效", "高级", "高速", "高亮", "高手", "高兴", "王国", "王者",
	"黄河", "黄色", "方法", "方向", "方式", "方案", "方便", "方面", "程序", "程度", "温度", "白色",
	"金额", "金融", "江湖", "石头", "马上", "周期", "周末", "周围", "周边", "文件", "文本", "文档",
	"文字", "文章", "余额", "安全", "安装", "安排", "钱包", "叶子", "毛病", "毛利", "毛重", "毛坯", "毛巾", "毛衣", "万一", "雷达", "宋体",
	"常量", "常用", "常见", "向量", "向上", "全部", "全局", "全面", "史上", "易用", "武器", "时间",
	"时候", "明天", "明确", "明白", "任何", "任务", "任意", "华为", "管理", "简单", "简介", "范围",
	"许多", "许可", "包括", "包含", "关于", "关系", "关闭", "连接", "成功", "成为", "应用", "应该",
	"单位", "单元", "单独", "司机", "车辆", "车子", "路径", "路由", "林业", "龙头", "柏林", "米饭",
	"宁可", "师傅", "老师", "老板", "老婆", "老公", "老家", "小时", "小心", "小说", "小姐", "小孩",
	"小组", "周一", "周二", "周三", "周四", "周五", "周六", "周日", "周天", "文案", "文风", "文化",
	"文学", "文明", "文献", "文法", "文具", "方块", "方针", "方程", "方框", "关键", "关注", "关联",
	"关心", "关掉", "项目", "成本", "成员", "成果", "成绩", "成熟", "成就", "解决", "解析", "解释",
	"解码", "段落", "章节", "颜色", "蓝色", "查询", "查看", "查找", "单词", "单个", "单击", "包装",
	"包名", "时区", "时长", "时段", "时刻", "时代", "季度", "严格", "严重", "曾经", "麻烦", "安卓",
	"谷歌", "常规", "常数", "边框", "边界", "边缘", "付费", "付款", "路线", "简洁", "简历", "简化",
	"范例", "游戏", "游客", "商品", "商店", "商业", "左边", "左侧", "焦点", "毕竟", "尚未",
	"陆续", "连续", "连线", "林间", "林区", "谢谢", "顾客", "顾问", "房间", "房子", "高端", "高层",
	"古代", "古典", "农业", "司法", "施工", "卫生", "荣誉", "宗旨", "齐全", "凌晨", "冷却", "蒙版",
	"曲线", "黄金", "白天", "白板", "白名", "金钱", "石油", "夏天", "夏季", "唐朝", "宋朝", "秦朝", "申请",
	"符号", "景色", "费用", "舒服", "辛苦", "纪律", "席位", "车间", "管道", "何时", "何况", "于是",
	"余下", "杜绝", "罗列", "程式", "叶片", "涂层", "沙发", "池子", "巩固", "迟到", "仲裁", "钟点",
	"钟表", "向导", "史诗", "易懂", "马路", "马虎", "汤汁", "朱红", "阳光", "任职", "董事",
	"边距", "边栏", "尚需",
)

var zhDictText string

var zhDict = func() map[string]bool {
	m := map[string]bool{}
	for _, l := range strings.Split(zhDictText, "\n") {
		if strings.HasPrefix(l, "#") {
			continue
		}
		for _, w := range strings.Fields(l) {
			m[w] = true
		}
	}
	return m
}()

const zhColours = "红橙黄绿蓝紫黑白灰褐棕粉赤"

const zhNounEnds = "词单字性率值码型键框栏库器类表量度点线层期区图版式页数论员价计费件名夹帧戳"

func zhWordShaped(v string) bool {
	rs := []rune(v)
	if len(rs) < 2 {
		return false
	}
	colour := true
	for _, r := range rs {
		if !unicode.Is(unicode.Han, r) {
			return false
		}
		colour = colour && strings.ContainsRune(zhColours, r)
	}
	if colour || rs[len(rs)-1] == '色' {
		return true
	}
	two := string(rs[:2])
	switch len(rs) {
	case 2:
		return zhWords[two] || zhDict[two]
	case 3:
		return (zhWords[two] || zhDict[two]) && strings.ContainsRune(zhNounEnds, rs[2])
	}
	return false
}

func zhWordNotName(s string, a, b int) bool {
	return zhWordShaped(s[a:b]) && !endsAny(s[:a], zhRoles, true) && !startsAny(s[b:], zhTitles)
}

var zhRoles = []string{"客户", "联系人", "作者", "提交者", "审核人", "审批人", "负责人", "经办人", "收件人", "发件人", "收货人", "申请人", "报告人", "同事", "姓名", "名字", "署名", "签名", "我叫", "他叫", "她叫", "名叫", "叫做", "尊敬的", "亲爱的", "致", "@"}

var zhBefore = []string{"给", "找", "问", "让", "告诉", "通知", "联系", "抄送", "转给", "交给", "一下", "叫", "和", "与", "跟", "说", "请", "我是", "他是", "她是"}

var zhAfter = []string{"先生", "女士", "小姐", "老师", "同学", "同志", "经理", "总监", "主任", "师傅", "医生", "律师", "教授", "博士", "说", "讲", "表示", "认为", "反馈", "提到", "提交", "负责", "告诉", "回复", "发", "打", "明天", "今天", "昨天", "已经", "他", "她"}

var zhAnyAfter = []string{"提交", "负责", "回复", "明天", "今天", "昨天", "已经", "他", "她"}

var zhAskVerbs = []string{"问", "找", "叫", "喊", "催", "请", "联系", "通知", "告诉", "提醒", "回复", "答复", "拜访", "采访", "抄送", "转告", "感谢", "谢谢", "艾特", "@"}

var zhTitles = []string{"先生", "女士", "小姐", "老师", "同学", "同志", "经理", "总监", "主任", "师傅", "医生", "律师", "教授", "博士"}

var (
	isSurname, isNick, notGiven = runes(zhSurnames), runes(zhNickSurnames), runes(zhNotGiven)
	mayStart                    = runes(zhSurnames + zhFirsts() + "小老")
)

func runes2(ws ...string) map[string]bool {
	m := map[string]bool{}
	for _, w := range ws {
		m[w] = true
	}
	return m
}

func zhWord(s string) bool {
	_, n := utf8.DecodeRuneInString(s)
	_, n2 := utf8.DecodeRuneInString(s[n:])
	return zhWords[s[:n+n2]]
}

func runes(s string) map[rune]bool {
	m := map[rune]bool{}
	for _, r := range s {
		m[r] = true
	}
	return m
}

func zhFirsts() string {
	var b strings.Builder
	for _, c := range zhCompound {
		r, _ := utf8.DecodeRuneInString(c)
		b.WriteRune(r)
	}
	return b.String()
}

func zhNameSpans(s string, person []span, nicks bool) []span {
	if !hasHan(s) {
		return nil
	}
	var cs []span
	for i := 0; i < len(s); {
		a, b, ok := zhName(s, i)
		if b == 0 {
			_, n := utf8.DecodeRuneInString(s[i:])
			i += n
			continue
		}
		i = b
		if nicks && !zhNick(s[a:b]) || zhWordNotName(s, a, b) {
			continue
		}
		kind := ""
		if ok {
			kind = "PERSON"
		}
		cs = append(cs, span{a, b, kind, ByModel, 0, false})
	}

	starts, ends := map[int]bool{}, map[int]bool{}
	for _, p := range person {
		starts[p.start], ends[p.end] = true, true
	}
	for _, c := range cs {
		if c.kind != "" {
			starts[c.start], ends[c.end] = true, true
		}
	}
	for grew := true; grew; {
		grew = false
		for i, c := range cs {
			if c.kind == "" && joined(s, c, starts, ends) {
				cs[i].kind, grew = "PERSON", true
				starts[c.start], ends[c.end] = true, true
			}
		}
	}
	var out []span
	for _, c := range cs {
		if c.kind != "" {
			out = append(out, c)
		}
	}
	return out
}

func zhNick(name string) bool {
	r, n := utf8.DecodeRuneInString(name)
	r2, n2 := utf8.DecodeRuneInString(name[n:])
	return (r == '小' || r == '老') && isNick[r2] && n+n2 == len(name)
}

func joined(s string, c span, starts, ends map[int]bool) bool {
	for _, j := range []string{"和", "与", "跟", "及", "、"} {
		if strings.HasPrefix(s[c.end:], j) && starts[c.end+len(j)] ||
			strings.HasSuffix(s[:c.start], j) && ends[c.start-len(j)] {
			return true
		}
	}
	return false
}

func zhName(s string, i int) (a, b int, ok bool) {
	rest := s[i:]
	if r, _ := utf8.DecodeRuneInString(rest); !mayStart[r] {
		return 0, 0, false
	}
	sur := 0
	for _, c := range zhCompound {
		if strings.HasPrefix(rest, c) {
			sur = len(c)
			break
		}
	}
	nick := false
	if sur == 0 {
		r, n := utf8.DecodeRuneInString(rest)
		switch {
		case (r == '小' || r == '老') && len(rest) > n:
			if r2, n2 := utf8.DecodeRuneInString(rest[n:]); isNick[r2] {
				sur, nick = n+n2, true
			}
		case isSurname[r]:
			sur = n
		}
	}
	if sur == 0 {
		return 0, 0, false
	}

	ends := []int{}
	if nick {
		ends = append(ends, i+sur)
	} else {
		at := i + sur
		for k := 0; k < 2 && at < len(s); k++ {
			r, n := utf8.DecodeRuneInString(s[at:])
			if !unicode.Is(unicode.Han, r) || notGiven[r] {
				break
			}
			at += n
			ends = append(ends, at)
		}
	}
	if len(ends) == 0 {
		return 0, 0, false
	}
	if zhWord(rest) {
		return 0, 0, false
	}

	before := s[:i]
	role, verb := endsAny(before, zhRoles, true), endsAny(before, zhBefore, false)

	for _, j := range []string{"和", "与"} {
		if t, ok := strings.CutSuffix(before, j); ok && verb {
			verb = personBefore(t)
		}
	}

	if t, ok := strings.CutSuffix(before, "一下"); ok && verb {
		verb = endsAny(t, zhAskVerbs, false)
	}
	start := sentenceStart(before)
	if !role && !verb && !start {
		return 0, 0, false
	}

	if !nick {
		for _, t := range append(zhTitles, "总") {
			if rest := s[i+sur:]; strings.HasPrefix(rest, t) && !(t == "总" && zhTotal(rest[len(t):])) {
				return i, i + sur + len(t), true
			}
		}
	}

	for k := len(ends) - 1; k >= 0; k-- {
		e := ends[k]
		if after := s[e:]; startsAny(after, zhAfter) && !wordAfter(after) && (role || verb || !startsAny(after, zhAnyAfter)) {
			return i, e, true
		} else if (role || verb) && endsWord(after) {
			return i, e, true
		}
	}
	if role {
		return i, ends[len(ends)-1], true
	}
	return i, ends[len(ends)-1], false
}

func zhTotal(s string) bool {
	r, _ := utf8.DecodeRuneInString(s)
	return strings.ContainsRune("是结共体之数计线量部归算会得要", r)
}

func endsAny(s string, ws []string, role bool) bool {
	if role {
		s = strings.TrimRight(s, " \t")
		for _, sep := range []string{"：", ":", "是", "为"} {
			if t, ok := strings.CutSuffix(s, sep); ok {
				s = strings.TrimRight(t, " \t")
				break
			}
		}
	}
	for _, w := range ws {
		if strings.HasSuffix(s, w) {
			return true
		}
	}
	return false
}

func startsAny(s string, ws []string) bool {
	for _, w := range ws {
		if strings.HasPrefix(s, w) {
			return true
		}
	}
	return false
}

func endsWord(s string) bool {
	r, _ := utf8.DecodeRuneInString(s)
	return s == "" || !unicode.Is(unicode.Han, r)
}

func sentenceStart(s string) bool {
	s = strings.TrimRight(s, " \t\u3000")
	if s == "" {
		return true
	}
	r, _ := utf8.DecodeLastRuneInString(s)
	return unicode.IsPunct(r) || unicode.IsSpace(r)
}

func wordAfter(s string) bool {
	for _, w := range []string{"说明", "说法", "讲解", "讲座", "讲义", "讲究"} {
		if strings.HasPrefix(s, w) {
			return !strings.HasPrefix(s, "说明天")
		}
	}
	for _, v := range []string{"发", "打"} {
		if t, ok := strings.CutPrefix(s, v); ok {
			r, _ := utf8.DecodeRuneInString(t)
			return unicode.Is(unicode.Han, r) && !strings.ContainsRune("了个给过一", r)
		}
	}
	return false
}

func personBefore(s string) bool {
	r, _ := utf8.DecodeLastRuneInString(s)
	if strings.ContainsRune("我你您他她们", r) {
		return true
	}
	rs := []rune(s)
	for n := 2; n <= 4 && n <= len(rs); n++ {
		u := string(rs[len(rs)-n:])
		if !mayStart[rs[len(rs)-n]] || !hasHan(u) {
			continue
		}
		if !zhWord(u) {
			return true
		}
	}
	return false
}

func zhTrim(s string, a, b int) (int, int) {
	v := s[a:b]
	if !hasHan(v) {
		return a, b
	}
	han := false
	for k, r := range v {
		if han && unicode.IsPunct(r) && r != '·' && r != '・' && utf8.RuneCountInString(v[:k]) >= 2 {
			v = v[:k]
			break
		}
		han = han || unicode.Is(unicode.Han, r)
	}
	for k := range v {
		if utf8.RuneCountInString(v[:k]) >= 2 && startsAny(v[k:], zhTitles) {
			v = v[:k]
			break
		}
	}
	return a, a + len(v)
}

func hasHan(s string) bool {
	for _, r := range s {
		if r >= 0x3400 && unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}

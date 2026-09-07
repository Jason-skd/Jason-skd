"""组件层（issue #3）：六个组件模块，各暴露模块级 render(config, data) -> str。

注册方式：流水线 assemble.import_registry() 按固定六个模块名
（banner/typing/stats/languages/org_card/recent_project）动态收集 render()，
本包 __init__ 不做任何注册或导入，保持可独立加载。

契约（issue #1 冻结）：
- render(config: dict, data: dict) -> str —— 纯函数，零 IO、零网络；
- config 形状 = {"theme": ..., "timezone": ..., "excludes": ..., **组件配置切片}
  （由流水线 config.section_config 注入，亦可手工构造，见 tests/fixtures）；
- data 形状 = data/*.json 反序列化结果（banner/typing 为空 dict）；
- 产出空串会被流水线校验门拒绝（绝不出半成品）。
"""
